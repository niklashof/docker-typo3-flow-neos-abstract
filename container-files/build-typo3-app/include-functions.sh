#!/bin/sh

#######################################
# Echo/log function
# Arguments:
#   String: value to log
#######################################
log() {
  if [ $@ ]; then echo "[${T3APP_NAME^^}] $@";
  else echo; fi
}

#########################################################
# Check in the loop (every 2s) if the database backend
# service is already available.
#########################################################
function wait_for_db() {
  set +e
  local RET=1
  while [[ RET -ne 0 ]]; do
    mysql $MYSQL_CMD_AUTH_PARAMS --execute "status" > /dev/null 2>&1
    RET=$?
    if [[ RET -ne 0 ]]; then
      log "Waiting for DB service..."
      sleep 2
    fi
  done
  set -e
  
  # Display DB status...
  mysql $MYSQL_CMD_AUTH_PARAMS --execute "status"
}

#########################################################
# Moves pre-installed in /tmp TYPO3 to its
# target location ($APP_ROOT), if it's not there yet
# Globals:
#   WEB_SERVER_ROOT
#   APP_ROOT
#   T3APP_NAME
#########################################################
function install_typo3_app() {
  # Check if app is already installed (when restaring stopped container)
  if [ ! -d $APP_ROOT ]; then
    log "Installing TYPO3 app (from pre-installed archive)..."
    cd $WEB_SERVER_ROOT && tar -zxf /tmp/$INSTALLED_PACKAGE_NAME.tgz
    mv $INSTALLED_PACKAGE_NAME $T3APP_NAME
  fi

  log "TYPO3 app installed."
  cd $APP_ROOT
  
  # Make sure cache is cleared for all contexts. This is empty during the 1st container launch,
  # but not clearing it when container re-starts can cause random issues.
  rm -rf rm -rf Data/Temporary/*
  
  # Debug: show most recent git log messages
  git log -5 --pretty=format:"%h %an %cr: %s" --graph # Show most recent changes
  
  # If app is/was already installed, pull most recent code
  if [ "${T3APP_ALWAYS_DO_PULL^^}" = TRUE ]; then
    log "Resetting current working directory..."
    git status && git clean -f -d && git reset --hard # make the working dir clean
    log "Pulling the newest codebase..."
    git pull
    git log -10 --pretty=format:"%h %an %cr: %s" --graph
  fi
  
  # If composer.lock has changed, this will re-install things...
  composer install $T3APP_BUILD_COMPOSER_PARAMS
}

#########################################################
# Creates database for TYPO3 app, if doesn't exist yet
# Globals:
#   MYSQL_CMD_AUTH_PARAMS
# Arguments:
#   String: db name to create
#########################################################
function create_app_db() {
  local db_name=$@
  log "Creating TYPO3 app database '$db_name' (if it doesn't exist yet)..."
  mysql $MYSQL_CMD_AUTH_PARAMS --execute="CREATE DATABASE IF NOT EXISTS $db_name CHARACTER SET utf8 COLLATE utf8_general_ci"
  log "DB created."
}

#########################################################
# Create Nginx vhost, if it doesn't exist yet
# Globals:
#   APP_ROOT
#   VHOST_FILE
#   VHOST_SOURCE_FILE
# Arguments:
#   String: virtual host name(s), space separated
#########################################################
function create_vhost_conf() {
  local vhost_names=$@
  local vhost_names_arr=($vhost_names)
  log "Configuring vhost in ${VHOST_FILE} for vhost(s) ${vhost_names}"

  # Create fresh vhost file on new data volume
  if [ ! -f $VHOST_FILE ]; then
    cat $VHOST_SOURCE_FILE > $VHOST_FILE
    log "New vhost file created."
  # Vhost already exist, but T3APP_FORCE_VHOST_CONF_UPDATE=true, so override it.
  elif [ "${T3APP_FORCE_VHOST_CONF_UPDATE^^}" = TRUE ]; then
    cat $VHOST_SOURCE_FILE > $VHOST_FILE
    log "Vhost file updated (as T3APP_FORCE_VHOST_CONF_UPDATE is TRUE)."
  fi

  sed -i -r "s#%server_name%#${vhost_names}#g" $VHOST_FILE
  sed -i -r "s#%root%#${APP_ROOT}#g" $VHOST_FILE
  
  # Configure redirect: www to non-www
  # @TODO: make it configurable via env var
  # @TODO: make possible reversed behaviour (non-www to www)
  sed -i -r "s#%server_name_primary%#${vhost_names_arr[0]}#g" $VHOST_FILE
  
  cat $VHOST_FILE
  log "Nginx vhost configured."
}

#########################################################
# Update TYPO3 app Settings.yaml with DB backend settings
# Globals:
#   SETTINGS_SOURCE_FILE
#   DB_ENV_MARIADB_PASS
#   DB_PORT_3306_TCP_ADDR
#   DB_PORT_3306_TCP_PORT
# Arguments:
#   String: filepath to config file to create/configure
#   String: database name to put in Settings.yaml
#########################################################
function create_settings_yaml() {
  local settings_file=$1
  local settings_db_name=$2

  mkdir -p $(dirname $settings_file)
  
  if [ ! -f $settings_file ]; then
    cat $SETTINGS_SOURCE_FILE > $settings_file
    log "Configuration file $settings_file created."
  fi

  log "Configuring $settings_file..."
  sed -i -r "1,/dbname:/s/dbname: .+?/dbname: $settings_db_name/g" $settings_file
  sed -i -r "1,/user:/s/user: .+?/user: admin/g" $settings_file
  sed -i -r "1,/password:/s/password: .+?/password: $DB_ENV_MARIADB_PASS/g" $settings_file
  sed -i -r "1,/host:/s/host: .+?/host: $DB_PORT_3306_TCP_ADDR/g" $settings_file
  sed -i -r "1,/port:/s/port: .+?/port: $DB_PORT_3306_TCP_PORT/g" $settings_file

  cat $settings_file
  log "$settings_file updated."
}

#########################################################
# Check latest TYPO3 doctrine:migration status.
# Used to detect if this is fresh installation
# or re-run from previous state.
#########################################################
function get_latest_db_migration() {
  log "Checking TYPO3 db migration status..."
  local v=$(./flow doctrine:migrationstatus | grep -i 'Current Version' | awk '{print $4$5$6}')
  log "Last db migration: $v"
  echo $v
}

#########################################################
# Provision database (i.e. doctrine:migrate)
#########################################################
function doctrine_update() {
  log "Doing doctrine:migrate..."
  ./flow doctrine:migrate --quiet
  log "Finished doctrine:migrate."
}

#########################################################
# Create admin user
#########################################################
function create_admin_user() {
  log "Creating admin user..."
  ./flow user:create --roles Administrator $T3APP_USER_NAME $T3APP_USER_PASS $T3APP_USER_FNAME $T3APP_USER_LNAME
}

#########################################################
# Install site package
# Arguments:
#   String: site package name to install
#########################################################
function neos_site_package_install() {
  local site_package_name=$@
  if [ "${site_package_name^^}" = FALSE ]; then
    log "Skipping installing site package (T3APP_NEOS_SITE_PACKAGE is set to FALSE)."
  else
    log "Installing $site_package_name site package..."
    ./flow site:import --packageKey $site_package_name
  fi
}

#########################################################
# Prune all site data.
# Used when re-importing the site package.
#########################################################
function neos_site_package_prune() {
  log "Pruning old site..."
  ./flow site:prune --confirmation
  log "Done."
}

#########################################################
# Warm up Flow caches for specified FLOW_CONTEXT
# Arguments:
#   String: FLOW_CONTEXT value, eg. Development, Production
#########################################################
function warmup_cache() {
  FLOW_CONTEXT=$@ ./flow flow:cache:flush --force;
  FLOW_CONTEXT=$@ ./flow cache:warmup;
}

#########################################################
# Set correct permission for TYPO3 app
#########################################################
function set_permissions() {
  chown -R www:www $APP_ROOT
}

#########################################################
# If the installed TYPO3 app contains
# executable $T3APP_USER_BUILD_SCRIPT file, it will run it.
# This script can be used to do all necessary steps to make
# the site up&running, e.g. compile CSS.
#########################################################
function user_build_script() {
  cd $APP_ROOT;
  if [[ -x $T3APP_USER_BUILD_SCRIPT ]]; then
    # Run ./build.sh script as 'www' user
    su www -c $T3APP_USER_BUILD_SCRIPT
  fi
}

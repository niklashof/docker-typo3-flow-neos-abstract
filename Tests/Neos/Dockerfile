FROM million12/typo3-flow-neos-abstract:latest
MAINTAINER Marcin Ryzycki marcin@m12.io

# ENV: Repository for installed TYPO3 Neos distribution 
ENV T3APP_BUILD_REPO_URL git://git.typo3.org/Neos/Distributions/Base.git

# ENV: Install the following Neos version
ENV T3APP_BUILD_BRANCH master

# ENV: Import following site package
ENV T3APP_NEOS_SITE_PACKAGE TYPO3.NeosDemoTypo3Org

# Pre-install TYPO3 Neos into /tmp directory
RUN . /build-typo3-app/pre-install-typo3-app.sh

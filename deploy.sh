#!/bin/bash

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

function deploy_basicservices() {
    ./deployments/basicservices/deploy.sh
}

function deploy_testapp() {
    ./deployments/testapp/deploy.sh
}

pushd $SCRIPT_DIR
deploy_basicservices
deploy_testapp
popd
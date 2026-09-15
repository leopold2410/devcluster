#!/bin/bash
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

function deploy_metallb() {
    ./metallb/deploy.sh
}

function deploy_traefik() {
    ./traefik/deploy.sh install
}

function deploy_istio() {
    ./istio/deploy.sh
}

function deploy_argocd() {
    kubectl apply -k ./argocd/base
}

pushd $SCRIPT_DIR
deploy_metallb
deploy_istio
#deploy_traefik
#deploy_argocd
popd
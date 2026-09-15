#!/bin/bash

function install_prerequisites() {
    kubectl apply -k prerequisites
}

function install() {
    kubectl kustomize base --enable-helm | kubectl apply -f -
}

case $1 in
  "install")
    install_prerequisites
    install    
    ;;
   *) echo "usage: deploy install" ;;
esac



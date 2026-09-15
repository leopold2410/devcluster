#!/bin/bash

function create_cluster() {
    local cluster_name=$1
    ./kind create cluster --config cluster-config.yaml --name $cluster_name
}

create_cluster dev
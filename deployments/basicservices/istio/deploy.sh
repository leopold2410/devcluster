#!/bin/bash
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
pushd $SCRIPT_DIR
helm upgrade istio-base istio/base --install --namespace istio-system --create-namespace --set defaultRevision=default --wait
helm upgrade istiod istio/istiod --install --namespace istio-system --wait
helm upgrade istio-ingress istio/gateway --install --namespace istio-system --wait
popd
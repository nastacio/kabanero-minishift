#!/bin/bash

set -e
set +x

curdir=`pwd`
scriptdir=$(pwd `dirname "${0}"`)
scriptname=`basename "${0}"`

#
# Parameter defaults
#
minishift_profile=kabanero
vm_driver=kvm
osx_vm_driver=hyperkit

docker_registry=https://index.docker.io/v1/

line="--------------------------------------------------------------------------------"

#
# Usage statement
#
function usage() {
    echo "Creates the Kabanero foundation environment for local development."
    echo ""
    echo "For problems related to minishift, please refer to the minishift troubleshooting guide:"
    echo "https://docs.okd.io/latest/minishift/troubleshooting/index.html"
    echo
    echo "Usage: $scriptname [OPTIONS]...[ARGS]"
    echo
    echo "  -i  | --install    Installs and configures Kabanero on an OKD installation using minishift."
    echo "  -p  | --profile <profile_name>"
    echo "                     Optional name for the minishift profile. Default is ${minishift_profile}."
    echo "  -d  | --vm-driver <hypervisor_driver>"
    echo "                     Optional choice for the vm-driver. Default is ${vm_driver}."
    echo "                     Default for MacOS is ${osx_vm_driver}."
    echo "        --clean-pipelines"
    echo "                     Delete all Tekton pipelines and related objects from Kabanero."
    echo "  -t  | --teardown   Uninstalls the minishift Kabanero VM."
    echo "      | --validate   Validate the Kabanero installation."
    echo "  -r  | --remote-registry"
    echo "                     Indicates whether a remote docker registry should be used."
    echo "      | --registry-url <docker_registry>"
    echo "                     URL of remote docker registry. Default is: ${docker_registry}"
    echo "                     Only used if --remote-registry was specified."
    echo "      | --registry-user <docker_user>"
    echo "                     User in remote docker registry"
    echo "                     Only used if --remote-registry was specified."
    echo "      | --registry-password <docker_password>"
    echo "                     Password for docker user in remote docker registry"
    echo "                     Only used if --remote-registry was specified."
    echo "      | --registry-email <docker_email>"
    echo "                     Email account of docker user in remote docker registry"
    echo "                     Only used if --remote-registry was specified."
    echo ""
    echo "  -v  | --verbose    Prints extra information about each command."
    echo "  -h  | --help       Output this usage statement."
}


#
# Echo message preffixed with a timestamp
#
# arg1 message 
#
function logts {
    echo "$(date -R)  ${1}"
}


#
# Secures the Docker registry
#
# Based on https://docs.okd.io/latest/install_config/registry/securing_and_exposing_registry.html
#          https://blog.openshift.com/remotely-push-pull-container-images-openshift/
#
function secureDockerRegistry() {
    logts "INFO: Securing Docker Registry"

    # https://docs.okd.io/latest/dev_guide/secrets.html#service-serving-certificate-secrets
    oc annotate service  docker-registry  -n default service.alpha.openshift.io/serving-cert-secret-name="registry-certificates"

    logts "INFO: Waiting for registry-certificates secret to become available"
    sleep 2
    until oc get secret registry-certificates -n default 
    do
         sleep 2
    done

    oc secrets link registry registry-certificates -n default
    oc secrets link default  registry-certificates -n default

    oc rollout pause dc/docker-registry -n default
    oc set volume dc/docker-registry --add --type=secret --secret-name=registry-certificates -m /etc/secrets -n default 
    oc set env dc/docker-registry \
    REGISTRY_HTTP_TLS_CERTIFICATE=/etc/secrets/tls.crt \
    REGISTRY_HTTP_TLS_KEY=/etc/secrets/tls.key -n default

    oc patch dc/docker-registry -p '{"spec": {"template": {"spec": {"containers":[{
    "name":"registry",
    "livenessProbe":  {"httpGet": {"scheme":"HTTPS"}}
  }]}}}}' -n default

    oc patch dc/docker-registry -p '{"spec": {"template": {"spec": {"containers":[{
    "name":"registry",
    "readinessProbe":  {"httpGet": {"scheme":"HTTPS"}}
  }]}}}}' -n default

    oc rollout resume dc/docker-registry -n default

    logts "INFO: Updating trusted certificate database with cert for internal docker registry"
    # https://docs.openshift.com/online/dev_guide/managing_images.html#using-image-pull-secrets
    # minishift --profile ${minishift_profile} ssh "echo \"$(oc get secret registry-certificates -n default -o "jsonpath={.data.tls\.crt}" | base64 -D)\" | sudo tee  /usr/share/pki/ca-trust-source/anchors/local.registry.ca.crt"
    # minishift --profile ${minishift_profile} ssh "sudo update-ca-trust"
    # minishift --profile ${minishift_profile} openshift restart

    # https://docs.openshift.com/online/dev_guide/secrets.html
    # https://github.com/knative/serving/issues/2136#issuecomment-438387033
    # oc set env -n knative-serving deployment/controller SSL_CERT_DIR=/var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt 
    # https://docs.openshift.com/online/dev_guide/managing_images.html#insecure-registries  

    logts "INFO: Secured Docker Registry"

    if [ $verbose -eq 1 ]; then
        logts "DEBUG: Docker Registry logs" 
        oc logs $(oc get pods -l docker-registry=default -n default  --output=jsonpath={.items[0].metadata.name}) -n default  --all-containers | grep -v healthz
    fi
}


#
# Clones the git repository for the Kabanero scripts
# 
# arg1 Temporary work directory for this script run
#
function cloneKabaneroScripts() {
    tmpdir="${1}"
    mkdir -p "${tmpdir}"
    rm -rf "${tmpdir}/kabanero-foundation"
    cd "${tmpdir}"
    git clone https://github.com/kabanero-io/kabanero-foundation.git
}


#
# Deletes the minishift Kabanero profile and deletes all its cached data.
#
function tearDownKabaneroMinishift() {
    minishift delete --profile ${minishift_profile}
    minishift profile delete kabanero
}


#
#
#
function checkMacOSPrereqs() {

    # MacOS Install
    which brew > /dev/null || 
    (logts "ERROR: brew package manager not found. Refer to https://brew.sh/ for installation instructions."
     return 1)

    logts "INFO: Initiating Kabanero installation on minishift."

    # Install minishift (OKD)
    # https://docs.okd.io/latest/minishift/getting-started/quickstart.html
    brew cask info minishift  > /dev/null || brew cask install minishift
    minishift_version=$(brew cask info minishift | head -n 1 | cut -d " " -f 2)
    [[ "${minishift_version}" < "1.33" ]] && \
        (logts "ERROR: minishift version [${minishift_version}] is not supoorted. Run \"brew cask upgrade minishift\"" ; 
         return 1)

    # hypervisor=xhyve
    hypervisor=$osx_vm_driver
    docker_hypervisor=docker-machine-driver-${hypervisor}
    brew info ${docker_hypervisor} > /dev/null || \
        (logts "ERROR: hypervisor is not configured, refer to https://docs.okd.io/latest/minishift/getting-started/setting-up-virtualization-environment.html#setting-up-${hypervisor}-driver" ;
         return 1)

    logts "INFO: Checking if hypervisor ${hypervisor} is installed."

    hypervisor_version=$(brew info ${docker_hypervisor}  | tail -n +1 | head -n 1 | cut -d " " -f 3)
    min_version="0.2.0"
    if [ "${hypervisor}" == "hyperkit" ]; then
       min_version="0.20190802"
    fi
    if [[ "${hypervisor_version}" < ${min_version} ]]; then
        (logts "ERROR: hypervisor version [${hypervisor_version}] is not supoorted. Run \"brew upgrade ${docker_hypervisor}\"" ; 
         return 1)
    fi

}


#
#
#
function checkLinuxPrereqs() {

    # https://docs.okd.io/latest/minishift/getting-started/setting-up-virtualization-environment.html#setting-up-kvm-driver
    if [ ! -e /usr/local/bin/docker-machine-driver-kvm ]; then
        sudo apt-get update
        sudo apt install qemu-kvm libvirt-daemon libvirt-daemon-system -y
        sudo usermod -a -G libvirt $(whoami)
        newgrp libvirt
        sudo curl -L https://github.com/dhiltgen/docker-machine-kvm/releases/download/v0.10.0/docker-machine-driver-kvm-ubuntu16.04 -o /usr/local/bin/docker-machine-driver-kvm
        sudo chmod +x /usr/local/bin/docker-machine-driver-kvm
    fi

    minishift_dir=~/tmp/minishift-1.34.1-linux-amd64/
    
    which minishift > /dev/null || (
        # Download minishift
        mkdir -p ~/tmp
        cd ~/tmp
        rm -rf ${minishift_dir}
        curl -L https://github.com/minishift/minishift/releases/download/v1.34.1/minishift-1.34.1-linux-amd64.tgz | tar zxf -
        cd ${minishift_dir}
        sudo cp -f minishift /usr/local/bin
        rm -rf ${minishift_dir}
    )

    hypervisor=kvm
}


#
# Installs minishift and creates a Kabanero profile with the Kabanero Foundation
# software.
#
# Based on instructions from
# https://kabanero.io/docs/ref/general/#scripted-kabanero-foundation-setup.html
#
function createKabaneroMinishift() {
    local result=1

    case $(uname) in
        "Darwin")
        checkMacOSPrereqs
        ;;
        "Linux")
        checkLinuxPrereqs
        ;;
        *)
        logts "ERROR: Unsupported platform for this script: $(uname)"
        usage
        exit 1
    esac

    if [ "${MINISHIFT_GITHUB_API_TOKEN}" == "" ]; then
        logts "INFO: You do not have a github API token exported as MINISHIFT_GITHUB_API_TOKEN"
        logts "INFO: If your installation fails due to GitHub API rate-limiting, visit https://github.com/minishift/minishift/blob/master/docs/source/troubleshooting/troubleshooting-getting-started.adoc for further instructions on how to create and use a GitHub API Token during this installation process."
    fi

    logts "INFO: Starting minishift profile ${minishift_profile}"
    logts "WARNING: VM restarts may require the profile to be recreated: https://docs.okd.io/latest/minishift/using/static-ip.html"
    log_level=1
    [ ${verbose} -eq 1 ] && log_level=3
    minishift start --vm-driver=${hypervisor} --profile ${minishift_profile} -v ${log_level} --cpus 4 --memory=6GB

    minishift oc-env --profile ${minishift_profile} 
    eval $(minishift oc-env --profile ${minishift_profile} )
    minishift docker-env --profile ${minishift_profile} 
    eval $(minishift docker-env --profile ${minishift_profile} )

    minishift --profile ${minishift_profile} ssh "echo \"*               -       nofile           16384\" | sudo tee -a /etc/security/limits.conf"

    # Validate env
    # oc new-app https://github.com/sclorg/nodejs-ex -l name=myapp
    # oc logs -f bc/nodejs-ex
    # oc status
    # oc status --suggest
    # oc get all
    # oc expose svc/nodejs-ex
    # oc get all --all-namespaces | grep nodejs
    # minishift openshift service nodejs-ex --in-browser

    oc login -u system:admin
    oc project default

    secureDockerRegistry

    logts "INFO: Starting Kabanero installation"
    # https://github.com/kabanero-io/docs/blob/master/ref/scripts/install-kabanero-foundation.sh
    cloneKabaneroScripts "${WORKDIR}"
    cd "${WORKDIR}/kabanero-foundation/scripts"
    openshift_master_default_subdomain=$(minishift ip).nip.io ./install-kabanero-foundation.sh
    result=$?
    cd - > /dev/null

    creatingContainers=$(oc get pods --all-namespaces --field-selector status.phase=Pending -o template --template={{.items}})
    until [ "${creatingContainers}" == "[]" ]; do
        sleep 10
        logts "INFO: Waiting for all containers to be created."
        oc get pods --all-namespaces --field-selector status.phase=Pending
        creatingContainers=$(oc get pods --all-namespaces --field-selector status.phase=Pending -o template --template={{.items}})
    done

    logts "INFO: Updating Knative CA repository with root CA for Docker Registry"
    if [ $(uname) == "Darwin" ]; then
        oc patch configmap config-service-ca -n knative-serving -p "{\"data\": { \"service-ca.crt\": \"$(oc get secret registry-certificates -n default -o "jsonpath={.data.tls\.crt}" | base64 -D | tr "\n" "'" | sed "s|'|\\\\n|g")\"}}"
    else
        oc patch configmap config-service-ca -n knative-serving -p "{\"data\": { \"service-ca.crt\": \"$(oc get secret registry-certificates -n default -o "jsonpath={.data.tls\.crt}" | base64 -d | tr "\n" "'" | sed "s|'|\\\\n|g")\"}}"
    fi

    oc scale deploy controller -n knative-serving --replicas=0
    sleep 5
    oc scale deploy controller -n knative-serving --replicas=1

    oc policy add-role-to-user tekton-dashboard-minimal developer
    oc policy add-role-to-user tekton-dashboard-minimal system

    logts "INFO: Kabanero installation on minishift is complete."

    oc get route -n kabanero

    return ${result}
}


#
#
#
function validateKabanero() {
    cloneKabaneroScripts "${WORKDIR}"
    cd "${WORKDIR}/kabanero-foundation/scripts"

    minishift oc-env --profile ${minishift_profile} 
    eval $(minishift oc-env --profile ${minishift_profile} )
    minishift docker-env --profile ${minishift_profile} 
    eval $(minishift docker-env --profile ${minishift_profile} )

    logts "INFO: Testing that regular users have permissions to push images to minishift registry."
    oc project kabanero
    oc login -u developer -p developer 
    docker_registry=$(minishift openshift registry --profile ${minishift_profile} )
    echo $(oc whoami -t) | docker login -u developer --password-stdin ${docker_registry}
    docker pull docker.io/busybox

    project_tag=${docker_registry}/myproject/busybox
    docker tag docker.io/busybox  ${project_tag}
    docker push ${project_tag}
    docker rmi ${project_tag}
    logts "INFO: Regular users have permissions to push images to minishift registry."

    oc login -u system:admin
    
    # Unclear if this is needed
    oc policy add-role-to-user registry-editor service-sa
    oc policy add-role-to-user registry-editor serviceaccount
    oc policy add-role-to-user registry-editor developer

    # Sample Appsody project with manual Tekton pipeline run
    # Create a Persistent Volume for the pipeline to use. A sample hostPath pv.yaml is provided.
    # READ THIS FIRST
    # https://developers.redhat.com/blog/2017/04/05/adding-persistent-storage-to-minishift-cdk-3-in-minutes/
    oc apply -f pv.yaml

    ## Create the pipeline and execute the example manual pipeline run
    #APP_REPO=https://github.com/nastacio/appsody-nodejs/  DOCKER_IMAGE="docker-registry.default.svc:5000/kabanero/appsody-hello-world" ./appsody-tekton-example-manual-run.sh 
    if [ ${remote_registry} -eq 1 ]; then 
        APP_REPO=https://github.com/nastacio/appsody-nodejs/  DOCKER_IMAGE="index.docker.io/${registry_user}/appsody-hello-world" DOCKER_USERNAME=${registry_user} DOCKER_PASSWORD=${registry_password} DOCKER_EMAIL=${registry_email} DOCKER_URL=${registry_url}  ${scriptdir}/appsody-tekton-example-manual-run.sh
    else
        APP_REPO=https://github.com/nastacio/appsody-nodejs/  ${scriptdir}/
    fi
    cd - > /dev/null

    # View manual pipeline logs
    logts "INFO: Waiting to assess pipeline status."
    until oc get pipelinerun.tekton.dev/manual-pipeline-run -n kabanero
    do
        sleep 5
    done
    runComplete=""
    until [ "${runComplete}" == "True" ] || [ "${runComplete}" == "False" ]; do
        runComplete=$(oc get pipelinerun.tekton.dev/manual-pipeline-run -n kabanero -o template  --template="{{(index .status.conditions 0).status}}")
        sleep 5
    done

    oc login -u developer -p developer 
    echo $(oc whoami -t) | docker login -u developer --password-stdin ${docker_registry}
    docker images

    oc login -u system:admin
    oc logs $(oc get pods -l tekton.dev/pipelineRun=manual-pipeline-run  -n kabanero --output=jsonpath={.items[0].metadata.name}) -n kabanero --all-containers
}


#
#
#
function deleteAllTektonPipelines() {
    oc login -u system:admin

    oc get pipelineruns -n kabanero | tr -s " " | cut -d " " -f 1| grep -v NAME  | xargs -I name oc -n kabanero delete pipelineruns name
    oc get pipelineresources -n kabanero | tr -s " " | cut -d " " -f 1 | grep -v NAME  | xargs -I name oc -n kabanero delete pipelineresources name
    oc get pipelines -n kabanero | grep appsody | tr -s " " | cut -d " " -f 1 | xargs -I name oc -n kabanero delete pipelines name
}


#
#
#
function createAlternativePipelineDefinition() {
    oc login -u system:admin

     oc delete -n kabanero -f appsody-build-task2.json
     oc delete -n kabanero -f appsody-build-pipeline2.yaml
     oc delete -n kabanero -f appsody-pipeline-run2.yaml

     oc apply -n kabanero -f appsody-build-task2.json --overwrite=true --validate=true --wait=true
     oc apply -n kabanero -f appsody-build-pipeline2.yaml --overwrite=true --validate=true --wait=true
     oc apply -n kabanero -f appsody-pipeline-run2.yaml --overwrite=true --validate=true --wait=true

     oc logs -f $(oc get pods -l tekton.dev/pipelineRun=manual-pipeline-run8  -n kabanero --output=jsonpath={.items[0].metadata.name}) -n kabanero --all-containers


    #docker_secret=deployer-dockercfg-9vnpc
    docker_secret=appsody-sa-token-4r4wt
    mkdir -p .docker
    oc get secret ${docker_secret} -n appsody-project -o "jsonpath={.data.\.dockercfg}" | base64 -D > .docker/config.json
    oc get secret ${docker_secret} -n appsody-project -o "jsonpath={.metadata.annotations.openshift\.io/token\-secret\.value}" | docker --config .docker login -u serviceaccount --password-stdin  $(minishift openshift registry)

    docker_secret=$(oc get secrets -n kabanero | grep appsody-sa-docker | cut -d " " -f 1)
    oc get secret ${docker_secret} -n kabanero -o "jsonpath={.data.\.dockercfg}" | base64 -D > .docker/config.json
    oc get secret ${docker_secret} -n kabanero -o "jsonpath={.metadata.annotations.openshift\.io/token\-secret\.value}" | docker --config .docker login -u serviceaccount --password-stdin  $(minishift openshift registry)

}


#
# Parameters
#
install=0
teardown=0
validate=0
verbose=0
cleanPipes=0

remote_registry=0
registry_url=""
docker_user=""
docker_password=""
docker_email=""

while [[ $# > 0 ]]
do
key="$1"
shift
case $key in
    -i|--install)
    install=1
    ;;
    -t|--teardown)
    teardown=1
    ;;
    -p|--profile)
    minishift_profile=$1
    shift
    ;;
    -d |--vm-driver)
    vm_driver=$1
    osx_vm_driver=$1
    shift
    ;;
    --clean-pipelines)
    cleanPipes=1
    ;;
    --validate)
    validate=1
    ;;
    -r|--remote-registry)
    remote_registry=1
    ;;
    --registry-url)
    registry_url=$1
    shift
    ;;
    --registry-user)
    docker_user=$1
    shift
    ;;
    --registry-password)
    docker_password=$1
    shift
    ;;
    --registry-email)
    docker_email=$1
    shift
    ;;
    -h|--help)
    usage
    exit
    ;;
    -v|--verbose)
    verbose=1
    ;;
    *)
    echo "Unrecognized parameter: $key"
    usage
    exit 1
esac
done

#
# Parameter checks
#
if [ ${validate} -eq 1 ] && [ ${teardown} -eq 1 ]; then
    logts "ERROR: The validate and teardown options are mutually exclusive."
    exit 1
fi
if [ ${install} -eq 1 ] && [ ${teardown} -eq 1 ]; then
    logts "ERROR: The install and teardown options are mutually exclusive."
    exit 1
fi
if [ ${install} -eq 0 ] && [ ${teardown} -eq 0 ] && [ ${validate} -eq 0 ]; then
    logts "ERROR: No option was selected."
    usage
    exit 1
fi

which git > /dev/null || 
    (echo "git CLI not installed"
     exit 2)

which docker > /dev/null || 
    (echo "docker CLI not installed"
     echo "Refer to https://docs.docker.com/install/"
     exit 3)

result=0

WORKDIR=$(mktemp -d -t ${scriptname}XXX) || exit 1
function cleanWorkDir() {
    if [ ! "$WORKDIR" == "" ]; then
        rm -rf $WORKDIR
    fi
}
trap cleanWorkDir EXIT

if [ ${install} -eq 1 ]; then
    createKabaneroMinishift
    result=$?
fi

if [ ${validate} -eq 1 ]; then
    validateKabanero
    result=$?
fi

if [ ${cleanPipes} -eq 1 ]; then
    deleteAllTektonPipelines
    result=$?
fi

if [ ${teardown} -eq 1 ]; then
    tearDownKabaneroMinishift
    result=$?
fi

exit ${result}

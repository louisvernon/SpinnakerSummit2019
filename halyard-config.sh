# execute from remote path
cd $(cd -P -- "$(dirname -- "$0")" && pwd -P)

BACKUP_ID=$(date  '+%d-%M-%Y-%s')
mv ~/.hal ~/hal$BACKUP_ID

source config_vars

if [! "$CLSID" = "" ]; then 
  $QUIET = "-q"
fi

#kubectl config current-context
hal $QUIET  config version edit --version ${SPINNAKER_VERSION}

wget --quiet https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-sdk-${GCLOUD_VERSION}-linux-x86_64.tar.gz
tar xf google-cloud-sdk-${GCLOUD_VERSION}-linux-x86_64.tar.gz

google-cloud-sdk/bin/gcloud auth activate-service-account --key-file=/tmp/account.json
google-cloud-sdk/bin/gcloud container clusters get-credentials ${cluster_name} --zone ${zone} --project ${project}

secret=$(kubectl get sa ${SPINNAKER_SERVICE_ACCOUNT} -o jsonpath={..secrets..name})
kubectl get secret ${secret} -o jsonpath={..token} > /tmp/LOCAL_TOKEN
SPINNAKER_PROFILE=$(kubectl config current-context)
kubectl config set-credentials ${SPINNAKER_PROFILE}  --token=$(cat /tmp/LOCAL_TOKEN | base64 -d)

# let's build the contexts for all other clusters and register pubsub queues while we're at it
hal config pubsub google enable

cat managed_clusters | while IFS=: read -r MANAGED_CLUSTER MPROJECT MZONE; do
  echo "Adding kubectl context for cluster ${MANAGED_CLUSTER} in project ${MPROJECT} with spinnaker"
  google-cloud-sdk/bin/gcloud container clusters get-credentials ${MANAGED_CLUSTER} --zone ${MZONE} --project ${MPROJECT}

  secret=$(kubectl get sa ${SPINNAKER_SERVICE_ACCOUNT} -o jsonpath={..secrets..name})
  kubectl get secret ${secret} -o jsonpath={..token} > /tmp/${MANAGED_CLUSTER}_TOKEN
  USER_PROFILE=$(kubectl config current-context)
  kubectl config set-credentials ${USER_PROFILE} --token $(cat /tmp/${MANAGED_CLUSTER}_TOKEN | base64 -d)

  echo "Creating subscription ${SUBSCRIPTION} for GCR pubsub topics"

  SUBSCRIPTION=spinnaker-${project}-${MPROJECT}-gcr
  {
    google-cloud-sdk/bin/gcloud -q beta pubsub subscriptions create $SUBSCRIPTION  --topic projects/${MPROJECT}/topics/gcr --topic-project ${MPROJECT}
  } || {
   echo "${SUBSCRIPTION} already exists"
  }
    
  hal config pubsub google subscription add $SUBSCRIPTION \
  --subscription-name $SUBSCRIPTION \
  --json-path /tmp/account.json \
  --project $MPROJECT \
  --message-format GCR

done

kubectl config use-context ${SPINNAKER_PROFILE}

kubectl get secret deployment -o jsonpath="{..SPINNAKER_GH_TOKEN}" | base64 -d > /tmp/GH_TOKEN


# enable the kubernetes account
hal $QUIET  config provider kubernetes enable

# add gcs bucket
hal $QUIET  config storage gcs edit --project ${project} \
  --bucket-location ${SPINNAKER_BUCKET_LOCATION} \
  --bucket ${SPINNAKER_BUCKET} \
  --json-path=/tmp/account.json 

hal $QUIET  config storage edit --type gcs

# setup docker registries for config
hal $QUIET  config provider docker-registry account add spinnaker-usgcr-account --address=https://us.gcr.io --username=_json_key --password-file=/tmp/account.json
hal $QUIET  config provider docker-registry account edit spinnaker-usgcr-account --cache-interval-seconds 300
hal $QUIET  config provider docker-registry enable

hal $QUIET  config features edit --artifacts true

hal $QUIET  config artifact github enable


# uses personal github access toke

hal $QUIET  config artifact github account add github-artifact-account \
    --token-file /tmp/GH_TOKEN

hal $QUIET  config provider kubernetes account add ${cluster_name} \
  --docker-registries spinnaker-usgcr-account \
  --context ${SPINNAKER_PROFILE}

hal config security ui edit \
    --override-base-url ${SPINNAKER_UI_URL}

hal config security api edit \
    --override-base-url  ${SPINNAKER_API_URL}

hal $QUIET config deploy edit --account-name ${cluster_name} --type distributed  #--location spinnaker

kubectl get pods 


read -ra CONTEXTS <<<$(kubectl config view -o jsonpath='{.contexts[*].name}') 
for CONTEXT in "${CONTEXTS[@]}"; do 
  echo $CONTEXT
  if [ "$CONTEXT" != "$SPINNAKER_PROFILE" ]; then
    echo "Registering context ${CONTEXT} with Spinnaker"

    hal $QUIET config provider kubernetes account add ${CONTEXT}v2 \
    --provider-version v2 \
    --context ${CONTEXT}
    
    hal $QUIET config provider kubernetes account add ${CONTEXT##*_} \
    --provider-version v2 \
    --context ${CONTEXT}
  fi
done

echo "Deploying Spinnaker"


# setup authorization
export CREDENTIALS=/tmp/spinnaker_gsuite.json

hal config security authz google edit \
    --admin-username $ADMIN \
    --credential-path $CREDENTIALS \
    --domain $DOMAIN
    
hal config security authz edit --type google

# hal config security authz enable
# setup authentication
SPINNAKER_CLIENT_ID=$(kubectl get secret deployment -o jsonpath="{..SPINNAKER_CLIENT_ID}" | base64 -d)
SPINNAKER_CLIENT_SECRET=$(kubectl get secret deployment -o jsonpath="{..SPINNAKER_CLIENT_SECRET}" | base64 -d)

hal config security authn oauth2 edit \
  --client-id $SPINNAKER_CLIENT_ID \
  --client-secret $SPINNAKER_CLIENT_SECRET \
  --provider google \
  --pre-established-redirect-uri ${SPINNAKER_API_URL}/login \
  --user-info-requirements hd=$DOMAIN
  
hal config security authn oauth2 enable

# setup logging/monitoring
hal config metric-stores stackdriver edit \
    --credentials-path /tmp/account.json

#modify X-Forwarded- behaviour using custom conf:
mkdir ~/.hal/default/profiles
cp /tmp/patched_gate-local.yml ~/.hal/default/profiles/gate-local.yml

SPINNAKER_SLACK_TOKEN=$(kubectl get secret deployment -o jsonpath="{..SPINNAKER_SLACK_TOKEN}" | base64 -d)

echo $SPINNAKER_SLACK_TOKEN | hal config notification slack edit --bot-name dl_spinnaker --token

hal deploy apply

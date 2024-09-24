#!/bin/bash
############################################## Set These Parameters ####################
export opsmxIsdUrl=https://isd2408.argocd.opsmx.net
export K8S_NAMESPACE=isd2408
export K8S_SECRET_NAME=multiargo

###################################
export existPath='/gate/platformservice/v7/argo/doesExist?argoName='
export downloadPath='/gate/oes/argo/agents/'
export teststring='{"argoNameExist":true}'

############################################# Get Kubernetes Secrets ##########################
# Retrieve the username and password from the Kubernetes secret

export ISDuser=$(kubectl get secret $K8S_SECRET_NAME -n $K8S_NAMESPACE -o jsonpath='{.data.username}' | base64 --decode)
if [ $? -ne '0' ]; then 
    echo "ERROR: could not get ISDuser"
    exit 1
fi

export ISDpassword=$(kubectl get secret $K8S_SECRET_NAME -n $K8S_NAMESPACE -o jsonpath='{.data.password}' | base64 --decode)
if [ $? -ne '0' ]; then 
    echo "ERROR: could not get ISDpassword"
    exit 1
fi

export gituser=$(kubectl get secret  git-secret -n $K8S_NAMESPACE -o jsonpath='{.data.username}' | base64 --decode)
if [ $? -ne '0' ]; then 
    echo "ERROR: could not get gituser"
    exit 1
fi

export gitpassword=$(kubectl get secret git-secret -n $K8S_NAMESPACE -o jsonpath='{.data.password}' | base64 --decode)
if [ $? -ne '0' ]; then 
    echo "ERROR: could not get gitpassword"
    exit 1
fi


############################################# Authenticate and Get Session ID ##########################
curl -s -c cookie.txt  "${opsmxIsdUrl}/gate/login" --data "username=${ISDuser}&password=${ISDpassword}"

if [ -z cookie.txt ]; then
    echo "ERROR: Authentication failed, could not logged to ISD "
    exit 1
fi
echo logged in successfully to ISD
echo
echo looping over argocds in argocdlist.txt
rm -rf errorlist.txt
#####################################################################


while read argo
do
echo
echo
echo
argocdName=$(echo $argo | awk '{print $1}')
argocdNS=$(echo $argo | awk '{print $2}')
argocdURL=$(echo $argo | awk '{print $3}')
argocdDesc=$(echo $argo | awk '{print $4}')
argocdServiceName=$(echo $argo | awk '{print $5}')

mkdir -p ${argocdName}

echo working with $argocdName in namespace $argocdNS with URL $argocdURL and description $argocdDesc
echo checking if agent with name $argocdName exists

# Use session ID to check if agent exists
httpCode=$(curl -b cookie.txt  "${opsmxIsdUrl}${existPath}${argocdName}" -s -o output.json -w "%{http_code}") 

# -L in curl command to redirect automatically

echo $httpCode is the return code of the curl GET command
if [ $httpCode != "200" ]; then 
    echo "ERROR: could not add agent to ISD for $argocdName"
    echo "ERROR: could not add agent to ISD for $argocdName" >> errorlist.txt 
    cat output.json >> errorlist.txt
    continue
fi 

if grep -q "$teststring" output.json; then 
    echo "$argocdName was already added"
    cat output.json
    rm output.json
    echo
    continue
else
    echo "adding $argocdName as agent"
    url="$opsmxIsdUrl""$downloadPath""${argocdName}"/manifest?isExists=true'&nameSpace='"${argocdNS}"'&description='"$argocdDesc"'&argoCdUrl='"$argocdURL"'&rolloutsEnabled=false&isdUrl='"${opsmxIsdUrl}"
    echo "$url is the url"
    httpCode=$( curl -L -s -b cookie.txt -o manifest.yaml -w "%{http_code}" "$url" )
    echo "$httpCode is return code of the curl GET manifest command"
    if [ $httpCode != "200" ]; then 
        echo "ERROR could not get manifest for $argocdName"
        echo "ERROR could not get manifest for $argocdName" >> errorlist.txt 
        cat manifest.yml >> errorlist.txt
        echo 
        echo >> errorlist.txt 
        continue
    fi
fi
#cat manifest.yaml


#################################################### Get ArgoCD Creds ##############################
if kubectl get secret $argocdName -n $K8S_NAMESPACE ; then
echo secret exists
else 
echo please create secret for $argocdName for the username and password 
continue
fi

argocduser=$(kubectl get secret $argocdName -n $K8S_NAMESPACE -o jsonpath='{.data.username}' | base64 --decode)
if [ -z $argocduser ]; then 
    echo "ERROR: could not get argocduser for $argocdName"
    echo "ERROR: could not get argocduser for $argocdName" >> errorlist.txt
    continue
fi 
argocdpassword=$(kubectl get secret $argocdName -n $K8S_NAMESPACE -o jsonpath='{.data.password}' | base64 --decode)
if [ -z $argocdpassword ]; then 
    echo "ERROR: could not get argocdpassword for $argocdName"
    echo "ERROR: could not get argocdpassword for $argocdName" >> errorlist.txt
    continue
fi 

#################################################### Get ArgoCD Token ##############################
echo argocd url is $argocdURL
justURL=$(echo $argocdURL | sed 's@https://@@')
echo
echo $justURL --username=$argocduser --password=$argocdpassword  is being used
echo
argocd login $justURL --username=$argocduser --password=$argocdpassword --grpc-web --insecure
if [ $? -ne '0' ]; then 
    echo "ERROR: could not login to argocd $argocdURL, check if username and password are correct"
    echo >> errorlist.txt
    echo "ERROR: could not login to argocd $argocdURL, check if username and password are correct" >> errorlist.txt
    continue
fi 

argocdtoken=$(argocd account generate-token)
# Base64 encoding the token and removing spaces
encodedToken=$(echo -n "$argocdtoken" | base64 )
cleanedToken=$(echo "$encodedToken" | tr -d '[:space:]')


if [ -z "$encodedToken" ]; then
  echo "Failed to generate token, but the script will continue."
  encodedToken=""  # Optionally set a default or empty value.
  continue
else
  echo
  echo "Token generated successfully."
  echo $encodedToken is the token
echo

fi

# Remove spaces using sed
safe_token=$(echo "$cleanedToken" | sed 's/[&/\]/\\&/g')


# Using a safer delimiter if needed
sed -i "s|token: ARGOCD_TOKEN_WITH_BASE64ENCODED|token: $safe_token|" manifest.yaml
sed -i "s#url: http://argocd-server:80#url: http://$argocdServiceName:80#" manifest.yaml

#kubectl apply -f manifest.yaml -n $argocdNS
kubectl replace --force -f manifest.yaml -n $argocdNS

mv manifest.yaml ${argocdName}

gitrepo=$( git config --get remote.origin.url )
gitbranch=$( git rev-parse --abbrev-ref HEAD )

git add -A
git commit -m " added manifest for $argocdName"
git push


argocd repo add $gitrepo --username $gituser --password $gitpassword --insecure-skip-server-verification
argocd app create isdagent --repo $gitrepo --revision $gitbranch --path ${argocdName} --dest-namespace $argocdNS --dest-server https://kubernetes.default.svc --upsert --sync-policy automated
argocd app get isdagent 

#################################################### Create K8s Secrets ##############################
done < argocdlist.txt

# Get the pod name for the controller
export controllerPod=$(kubectl get po -n $K8S_NAMESPACE | grep opsmx-controller-controller1 | awk '{print $1}')

# Print the pod name (for debugging purposes)
echo "Controller Pod: $controllerPod"

# Delete the pod in the specified namespace
kubectl delete po $controllerPod -n $K8S_NAMESPACE

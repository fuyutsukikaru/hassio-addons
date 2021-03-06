#!/bin/bash

#### config ####

CONFIG_PATH=/data/options.json

DEPLOYMENT_KEY=$(jq --raw-output ".deployment_key[]" $CONFIG_PATH)
DEPLOYMENT_KEY_PROTOCOL=$(jq --raw-output ".deployment_key_protocol" $CONFIG_PATH)
DEPLOYMENT_USER=$(jq --raw-output ".deployment_user" $CONFIG_PATH)
DEPLOYMENT_PASSWORD=$(jq --raw-output ".deployment_password" $CONFIG_PATH)
GIT_BRANCH=$(jq --raw-output '.git_branch' $CONFIG_PATH)
GIT_COMMAND=$(jq --raw-output '.git_command' $CONFIG_PATH)
GIT_REMOTE=$(jq --raw-output '.git_remote' $CONFIG_PATH)
REPOSITORY=$(jq --raw-output '.repository' $CONFIG_PATH)
AUTO_RESTART=$(jq --raw-output '.auto_restart' $CONFIG_PATH)
REPEAT_ACTIVE=$(jq --raw-output '.repeat.active' $CONFIG_PATH)
REPEAT_INTERVAL=$(jq --raw-output '.repeat.interval' $CONFIG_PATH)
################

#### functions ####
function add-ssh-key {
    echo "[Info] Start adding SSH key"
    mkdir -p ~/.ssh

    (
        echo "Host *"
        echo "    StrictHostKeyChecking no"
    ) > ~/.ssh/config

    echo "[Info] Setup deployment_key on id_${DEPLOYMENT_KEY_PROTOCOL}"
    while read -r line; do
        echo "$line" >> "${HOME}/.ssh/id_${DEPLOYMENT_KEY_PROTOCOL}"
    done <<< "$DEPLOYMENT_KEY"

    chmod 600 "${HOME}/.ssh/config"
    chmod 600 "${HOME}/.ssh/id_${DEPLOYMENT_KEY_PROTOCOL}"
}

function git-clone {
    # create backup
    BACKUP_LOCATION="/tmp/config-$(date +%Y-%m-%d_%H-%M-%S)"
    echo "[Info] Backup configuration to $BACKUP_LOCATION"
    
    mkdir "${BACKUP_LOCATION}" || { echo "[Error] Creation of backup directory failed"; exit 1; }
    cp -rf /config/* "${BACKUP_LOCATION}" || { echo "[Error] Copy files to backup directory failed"; exit 1; }
    
    # remove config folder content
    rm -rf /config/{,.[!.],..?}* || { echo "[Error] Clearing /config failed"; exit 1; }

    # git clone
    echo "[Info] Start git clone"
    git clone "$REPOSITORY" /config || { echo "[Error] Git clone failed"; exit 1; }

    # try to copy non yml files back
    cp "${BACKUP_LOCATION}" "!(*.yaml)" /config 2>/dev/null

    # try to copy secrets file back
    cp "${BACKUP_LOCATION}/secrets.yaml" /config 2>/dev/null
}

function check-ssh-key {
if [ -n "$DEPLOYMENT_KEY" ]; then
    echo "Check SSH connection"
    IFS=':' read -ra GIT_URL_PARTS <<< "$REPOSITORY"
    # shellcheck disable=SC2029
    DOMAIN="${GIT_URL_PARTS[0]}"
    if OUTPUT_CHECK=$(ssh -T -o "StrictHostKeyChecking=no" -o "BatchMode=yes" "$DOMAIN" 2>&1) || { [[ $DOMAIN = *"@github.com"* ]] && [[ $OUTPUT_CHECK = *"You've successfully authenticated"* ]]; }; then
        echo "[Info] Valid SSH connection for $DOMAIN"
    else
        echo "[Warn] No valid SSH connection for $DOMAIN"
        add-ssh-key
    fi
fi
}

function setup-user-password {
if [ ! -z "$DEPLOYMENT_USER" ]; then
    cd /config || return
    echo "[Info] setting up credential.helper for user: ${DEPLOYMENT_USER}"
    git config --system credential.helper 'store --file=/tmp/git-credentials'

    # Extract the hostname from repository
    h="$REPOSITORY"

    # Extract the protocol
    proto=${h%%://*}

    # Strip the protocol
    h="${h#*://}"

    # Strip username and password from URL
    h="${h#*:*@}"
    h="${h#*@}"

    # Strip the tail of the URL
    h=${h%%/*}

    # Format the input for git credential commands
    cred_data="\
protocol=${proto}
host=${h}
username=${DEPLOYMENT_USER}
password=${DEPLOYMENT_PASSWORD}
"

    # Use git commands to write the credentials to ~/.git-credentials
    echo "[Info] Saving git credentials to /tmp/git-credentials"
    git credential fill | git credential approve <<< "$cred_data"
fi
}

function git-synchronize {
    # is /config a local git repo?
    if git rev-parse --is-inside-git-dir &>/dev/null
    then
        echo "[Info] Local git repository exists"

        # Is the local repo set to the correct origin?
        CURRENTGITREMOTEURL=$(git remote get-url --all "$GIT_REMOTE" | head -n 1)
        if [ "$CURRENTGITREMOTEURL" = "$REPOSITORY" ]
        then
            echo "[Info] Git origin is correctly set to $REPOSITORY"
            OLD_COMMIT=$(git rev-parse HEAD)
            
            # Pull or reset depending on user preference
            case "$GIT_COMMAND" in
                pull)
                    echo "[Info] Start git pull..."
                    git checkout "$GIT_BRANCH" || { echo "[Error] Git checkout failed"; exit 1; }
                    git pull || { echo "[Error] Git pull failed"; exit 1; }
                    ;;
                reset)
                    echo "[Info] Start git reset..."
                    git checkout "$GIT_BRANCH" || { echo "[Error] Git checkout failed"; exit 1; }
                    git fetch "$GIT_REMOTE" "$GIT_BRANCH" || { echo "[Error] Git fetch failed"; exit 1; }
                    git reset --hard "$GIT_REMOTE"/"$GIT_BRANCH" || { echo "[Error] Git reset failed"; exit 1; }
                    ;;
                *)
                    echo "[Error] Git command is not set correctly. Should be either 'reset' or 'pull'"
                    exit 1
                    ;;
            esac
        else
            echo "[Error] git origin does not match $REPOSITORY!"; exit 1;
        fi

    else
        echo "[Warn] Git repostory doesn't exist"
        git-clone
    fi
}

function validate-config {
    echo "[Info] Check if something is changed"
    # Compare commit ids & check config
    NEW_COMMIT=$(git rev-parse HEAD)
    if [ "$NEW_COMMIT" != "$OLD_COMMIT" ]; then
        echo "[Info] Something has changed, check Home-Assistant config"
        if hassio homeassistant check; then
            if [ "$AUTO_RESTART" == "true" ]; then
                echo "[Info] Restart Home-Assistant"
                hassio homeassistant restart 2&> /dev/null
            else
                echo "[Info] Local configuraiton has changed. Restart requried."
            fi
        else
            echo "[Error] Configuration updated but it does not pass the config check. Do not restart until this is fixed!"
        fi
    else
        echo "[Info] Nothing has changed."
    fi
}

###################

#### Main program ####
cd /config || { echo "[Error] Failed to cd into /config"; exit 1; }
while true; do
    check-ssh-key
    setup-user-password
    git-synchronize
    validate-config
     # do we repeat?
    if [ -z "$REPEAT_ACTIVE" ]; then
        exit 0
    fi
    sleep "$REPEAT_INTERVAL"
done

###################

#!/usr/bin/env bash
# Simplified testnode launcher for external sequencer development.
# Equivalent to: ./start.bash --init-force --no-simple --blockscout --detach
# Zero flags — completely hardcoded.

set -eu

# === Constants ===
NITRO_NODE_VERSION=nitro-node-dev:latest
BLOCKSCOUT_VERSION=offchainlabs/blockscout:v1.1.0-0e716c8
DEFAULT_NITRO_CONTRACTS_VERSION="v3.1.0"
DEFAULT_TOKEN_BRIDGE_VERSION="v1.2.2"

: ${NITRO_CONTRACTS_BRANCH:=$DEFAULT_NITRO_CONTRACTS_VERSION}
: ${TOKEN_BRIDGE_BRANCH:=$DEFAULT_TOKEN_BRIDGE_VERSION}
export NITRO_CONTRACTS_BRANCH
export TOKEN_BRIDGE_BRANCH

echo "Using NITRO_CONTRACTS_BRANCH: $NITRO_CONTRACTS_BRANCH"
echo "Using TOKEN_BRIDGE_BRANCH: $TOKEN_BRIDGE_BRANCH"

mydir=`dirname $0`
cd "$mydir"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# === Stop any existing testnode ===
echo == Stopping existing testnode
./stop.bash || true

# === Hardcoded config (--no-simple --blockscout, no redundant sequencers) ===
devprivkey=b6b15c8cb491557369f3c7d2c287b053eb229daa9c22138887752191c9520659
l1chainid=1337
SEQUENCER_SERVICE="sequencer"
INITIAL_SEQ_NODES="sequencer"
NODES="sequencer redis poster staker-unsafe blockscout"

# === WebSocket check function (from start.bash:638-752) ===
# Sequencer sometimes fails to start WS on first attempt; this retries.
run_container_with_websocket_check() {
    local container_name="$1"
    local websocket_port="$2"
    local max_retries="${3:-3}"
    local retry_wait="${4:-5}"

    if [ -z "$container_name" ] || [ -z "$websocket_port" ]; then
        echo "Error: Container name and WebSocket port are required"
        return 1
    fi

    echo "Starting container $container_name and checking WebSocket on port $websocket_port"

    check_websocket() {
        local ws_check_timeout=5
        local response
        (
            response=$(curl -s -S \
                --connect-timeout 3 \
                --max-time $ws_check_timeout \
                -D - \
                -o /dev/null \
                -H "Connection: Upgrade" \
                -H "Upgrade: websocket" \
                -H "Sec-WebSocket-Key: SGVsbG8sIHdvcmxkIQ==" \
                -H "Sec-WebSocket-Version: 13" \
                http://localhost:$websocket_port/ 2>/dev/null)
            if echo "$response" | grep -q "HTTP/1.1 101"; then
                exit 0
            fi
            exit 1
        ) &
        local check_pid=$!
        local check_timeout=10
        local waited=0
        while kill -0 $check_pid 2>/dev/null && [ $waited -lt $check_timeout ]; do
            sleep 1
            waited=$((waited + 1))
        done
        if kill -0 $check_pid 2>/dev/null; then
            kill -9 $check_pid 2>/dev/null
            echo "WebSocket check timed out"
            return 1
        fi
        wait $check_pid
        return $?
    }

    stop_container() {
        echo "Stopping container $container_name..."
        docker compose stop "$container_name"
        sleep 2
    }

    local retry_count=0
    local success=false

    while [ $retry_count -lt $max_retries ] && [ "$success" = false ]; do
        if [ $retry_count -gt 0 ]; then
            echo "Retry attempt $retry_count of $max_retries"
            stop_container
            echo "Waiting $retry_wait seconds before retry..."
            sleep $retry_wait
        fi

        echo "Starting container $container_name..."
        docker compose up -d "$container_name"

        local init_wait=10
        echo "Waiting ${init_wait}s for container to initialize..."
        sleep $init_wait

        echo "Checking WebSocket endpoint..."
        if check_websocket; then
            echo "Container $container_name is running with active WebSocket endpoint"
            success=true
        else
            echo "Container $container_name WebSocket endpoint is not active"
            retry_count=$((retry_count + 1))
        fi
    done

    if [ "$success" = true ]; then
        return 0
    else
        echo "Failed to start $container_name with active WebSocket after $max_retries attempts"
        stop_container
        return 1
    fi
}

# ============================================================================
# BUILD
# ============================================================================

echo == Building utilities
docker compose build --no-rm scripts rollupcreator

echo == Pulling Blockscout
docker pull $BLOCKSCOUT_VERSION
docker tag $BLOCKSCOUT_VERSION blockscout-testnode

echo == Building node images
docker compose build --no-rm $NODES

# ============================================================================
# INIT — CLEANUP
# ============================================================================

echo == Removing old data..
docker compose down --remove-orphans
leftoverContainers=`docker container ls -a --filter label=com.docker.compose.project=nitro-testnode -q | xargs echo`
if [ `echo $leftoverContainers | wc -w` -gt 0 ]; then
    docker rm $leftoverContainers
fi
docker volume prune -f --filter label=com.docker.compose.project=nitro-testnode
leftoverVolumes=`docker volume ls --filter label=com.docker.compose.project=nitro-testnode -q | xargs echo`
if [ `echo $leftoverVolumes | wc -w` -gt 0 ]; then
    docker volume rm $leftoverVolumes
fi

# ============================================================================
# INIT — L1 SETUP
# ============================================================================

echo == Generating l1 keys
docker compose run scripts write-accounts
docker compose run --entrypoint sh geth -c "echo passphrase > /datadir/passphrase"
docker compose run --entrypoint sh geth -c "chown -R 1000:1000 /keystore"
docker compose run --entrypoint sh geth -c "chown -R 1000:1000 /config"

echo == Writing geth configs
docker compose run scripts write-geth-genesis-config

echo == Initializing go-ethereum genesis configuration
docker compose run geth init --state.scheme hash --datadir /datadir/ /config/geth_genesis.json

echo == Starting geth
docker compose up --wait geth

echo == Waiting for geth to sync
docker compose run scripts wait-for-sync --url http://geth:8545

# ============================================================================
# INIT — FUNDING & L2 DEPLOY
# ============================================================================

echo == Funding validator, sequencer and l2owner
docker compose run scripts send-l1 --ethamount 1000 --to validator --wait
docker compose run scripts send-l1 --ethamount 1000 --to sequencer --wait
docker compose run scripts send-l1 --ethamount 1000 --to l2owner --wait

echo == create l1 traffic
docker compose run scripts send-l1 --ethamount 1000 --to user_l1user --wait
docker compose run scripts send-l1 --ethamount 0.0001 --from user_l1user --to user_l1user --wait --delay 1000 --times 1000000 > /dev/null &

l2ownerAddress=`docker compose run scripts print-address --account l2owner | tail -n 1 | tr -d '\r\n'`

echo == Writing l2 chain config
docker compose run scripts --l2owner $l2ownerAddress write-l2-chain-config

sequenceraddress=`docker compose run scripts print-address --account sequencer | tail -n 1 | tr -d '\r\n'`
l2ownerKey=`docker compose run scripts print-private-key --account l2owner | tail -n 1 | tr -d '\r\n'`
wasmroot=`docker compose run --entrypoint sh "$SEQUENCER_SERVICE" -c "cat /home/user/target/machines/latest/module-root.txt"`

echo == Deploying L2 chain
docker compose run -e PARENT_CHAIN_RPC="http://geth:8545" -e DEPLOYER_PRIVKEY=$l2ownerKey -e PARENT_CHAIN_ID=$l1chainid -e CHILD_CHAIN_NAME="arb-dev-test" -e MAX_DATA_SIZE=117964 -e OWNER_ADDRESS=$l2ownerAddress -e WASM_MODULE_ROOT=$wasmroot -e SEQUENCER_ADDRESS=$sequenceraddress -e AUTHORIZE_VALIDATORS=10 -e CHILD_CHAIN_CONFIG_PATH="/config/l2_chain_config.json" -e CHAIN_DEPLOYMENT_INFO="/config/deployment.json" -e CHILD_CHAIN_INFO="/config/deployed_chain_info.json" rollupcreator create-rollup-testnode
docker compose run --entrypoint sh rollupcreator -c "jq [.[]] /config/deployed_chain_info.json > /config/l2_chain_info.json"

# ============================================================================
# CONFIG — WRITE CONFIGS & INIT REDIS
# ============================================================================

echo == Writing configs
docker compose run scripts write-config

echo == Initializing redis
docker compose up --wait redis
docker compose run scripts redis-init --redundancy 0

echo == Generating Docker and native configs
docker compose run scripts write-docker-sequencer-config --dir "$SCRIPT_DIR"
docker compose run scripts write-docker-follower-config --dir "$SCRIPT_DIR"
docker compose run scripts write-native-sequencer-config --dir "$SCRIPT_DIR"
docker compose run scripts write-native-follower-config --dir "$SCRIPT_DIR"

# ============================================================================
# START SEQUENCER
# ============================================================================

echo == Starting sequencer
docker compose up -d "$SEQUENCER_SERVICE"
run_container_with_websocket_check "$SEQUENCER_SERVICE" 8548 5 10

# ============================================================================
# FUND L2
# ============================================================================

echo == Funding l2 funnel and dev key
docker compose up --wait $INITIAL_SEQ_NODES
docker compose run scripts bridge-funds --ethamount 100000 --wait
docker compose run scripts send-l2 --ethamount 100 --to l2owner --wait

echo == Deploy CacheManager on L2
docker compose run -e CHILD_CHAIN_RPC="http://sequencer:8547" -e CHAIN_OWNER_PRIVKEY=$l2ownerKey rollupcreator deploy-cachemanager-testnode

echo == Deploy Stylus Deployer on L2
docker compose run scripts create-stylus-deployer --deployer l2owner

# TODO: remove this once the gas estimation issue is fixed
echo == Gas Estimation workaround
docker compose run scripts send-l1 --ethamount 1 --to address_0x0000000000000000000000000000000000000000 --wait
docker compose run scripts send-l2 --ethamount 1 --to address_0x0000000000000000000000000000000000000000 --wait

# ============================================================================
# LAUNCH ALL SERVICES
# ============================================================================

echo == Launching all services
echo if things go wrong - use start.bash --init to create a new chain
echo

docker compose up --wait $NODES

# ============================================================================
# POST-LAUNCH CONFIG GENERATION
# ============================================================================

if [ -f "./data/config/sequencer_follower_config.json" ]; then
    echo "== Writing local sequencer config"
    jq --arg dir "$SCRIPT_DIR" '
        .["parent-chain"].connection.url = "ws://localhost:8546" |
        .chain["info-files"] = [$dir + "/data/config/l2_chain_info.json"] |
        .node.staker["parent-chain-wallet"].pathname = $dir + "/data/l1keystore" |
        .node["seq-coordinator"]["redis-url"] = "redis://localhost:6379" |
        .node["batch-poster"]["parent-chain-wallet"].pathname = $dir + "/data/l1keystore" |
        .node["batch-poster"]["redis-url"] = "redis://localhost:6379" |
        .node["block-validator"]["validation-server"].url = "ws://localhost:8949" |
        .node["block-validator"]["validation-server"].jwtsecret = $dir + "/data/config/val_jwt.hex"
    ' ./data/config/sequencer_follower_config.json > ./data/config/sequencer_follower_config_local.json
else
    echo "Warning: ./data/config/sequencer_follower_config.json does not exist. Skipping sequencer config update."
fi

echo
echo "== Done! Testnode is running."
echo "   Sequencer RPC: http://localhost:8547"
echo "   Blockscout:    http://localhost:4000"
echo "   Redis:         localhost:6379"

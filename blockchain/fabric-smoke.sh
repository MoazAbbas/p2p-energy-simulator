#!/usr/bin/env bash
# Fabric smoke test: start the official test network, create a channel, deploy the sample TypeScript
# chaincode, submit transactions, query them back, and time the submits.
#
# Run in Ubuntu (WSL):   bash blockchain/fabric-smoke.sh
# Optional argument: path to fabric-samples/test-network (default below).
# Everything is logged to ~/fabric-smoke.log. The network is left RUNNING at the end.
# Needs internet (Docker images and, for TypeScript chaincode, npm packages inside Docker).
set -u

TN="${1:-$HOME/projects/fabric-dev/fabric-samples/test-network}"
LOG="${FABRIC_SMOKE_LOG:-$HOME/fabric-smoke.log}"
: > "$LOG"
RESULTS=()

say() { echo "$@" | tee -a "$LOG"; }
step() { say ""; say "=== $1"; }
pass() { say "PASS: $1"; RESULTS+=("PASS  $1"); }
fail() {
  local recent
  recent=$(tail -25 "$LOG")
  say "FAIL: $1"
  echo ""
  echo "---- last lines of the log (full log: $LOG) ----"
  echo "$recent"
  echo "---- end ----"
  echo "Please paste everything from the line starting with '=== ' of the failing step down to here."
  exit 1
}
# run a command, append its output to the log, fail the step if it returns non-zero
run() {
  local desc="$1"; shift
  echo "\$ $*" >> "$LOG"
  if "$@" >> "$LOG" 2>&1; then pass "$desc"; else fail "$desc"; fi
}

step "0. Preflight"
[ -f "$TN/network.sh" ] || { say "network.sh not found in $TN"; say "Pass the right folder: bash blockchain/fabric-smoke.sh /path/to/fabric-samples/test-network"; exit 1; }
cd "$TN" || exit 1
say "test-network folder: $(pwd)"
docker info >> "$LOG" 2>&1 || fail "Docker is not reachable from Ubuntu (start Docker Desktop and enable WSL integration for Ubuntu)"
pass "Docker reachable"
[ -x ../bin/peer ] || fail "../bin/peer not found (Fabric binaries missing). Run: ./install-fabric.sh binary"
export PATH="$PWD/../bin:$PATH"
export FABRIC_CFG_PATH="$PWD/../config/"
say "peer binary: $(peer version 2>&1 | grep -E 'Version' | head -1)"
if docker images 2>/dev/null | grep -q "hyperledger/fabric-peer"; then
  say "docker images: $(docker images --format '{{.Repository}}:{{.Tag}}' | grep hyperledger | tr '\n' ' ')"
  pass "Fabric Docker images present"
else
  say "No hyperledger/fabric-peer image found locally. The next steps will try to pull images; if that fails run:"
  say "  curl -sSLO https://raw.githubusercontent.com/hyperledger/fabric/main/scripts/install-fabric.sh && chmod +x install-fabric.sh && ./install-fabric.sh docker"
fi
CC_DIR="../asset-transfer-basic/chaincode-typescript"
[ -d "$CC_DIR" ] || fail "sample chaincode folder $CC_DIR not found in your fabric-samples copy"
pass "TypeScript sample chaincode folder found"

step "1. Remove any previous network"
run "network.sh down" ./network.sh down

step "2. Start the network (peers, orderer, CAs as Docker containers)"
run "network.sh up" ./network.sh up
for name in peer0.org1.example.com peer0.org2.example.com orderer.example.com; do
  if docker ps --format '{{.Names}}' | grep -qx "$name"; then pass "container running: $name"; else fail "container not running: $name"; fi
done

step "3. Create the channel 'mychannel'"
run "network.sh createChannel" ./network.sh createChannel

step "4. Deploy the sample TypeScript chaincode 'basic' (this builds it in Docker and can take a few minutes)"
T0=$(date +%s)
run "network.sh deployCC" ./network.sh deployCC -ccn basic -ccp "$CC_DIR" -ccl typescript
say "deployCC took $(( $(date +%s) - T0 )) s"

step "5. Submit and query transactions as Org1"
export CORE_PEER_TLS_ENABLED=true
export CORE_PEER_LOCALMSPID=Org1MSP
export CORE_PEER_TLS_ROOTCERT_FILE="$PWD/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt"
export CORE_PEER_MSPCONFIGPATH="$PWD/organizations/peerOrganizations/org1.example.com/users/Admin@org1.example.com/msp"
export CORE_PEER_ADDRESS=localhost:7051
ORDERER_CA="$PWD/organizations/ordererOrganizations/example.com/orderers/orderer.example.com/msp/tlscacerts/tlsca.example.com-cert.pem"
ORG1_TLS="$PWD/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt"
ORG2_TLS="$PWD/organizations/peerOrganizations/org2.example.com/peers/peer0.org2.example.com/tls/ca.crt"
for f in "$ORDERER_CA" "$ORG1_TLS" "$ORG2_TLS" "$CORE_PEER_MSPCONFIGPATH"; do
  [ -e "$f" ] || fail "expected file not found: $f (the test-network folder layout may differ in your Fabric version)"
done

invoke() {
  peer chaincode invoke -o localhost:7050 --ordererTLSHostnameOverride orderer.example.com --tls \
    --cafile "$ORDERER_CA" -C mychannel -n basic \
    --peerAddresses localhost:7051 --tlsRootCertFiles "$ORG1_TLS" \
    --peerAddresses localhost:9051 --tlsRootCertFiles "$ORG2_TLS" \
    -c "$1"
}

echo "\$ peer chaincode invoke InitLedger" >> "$LOG"
OUT=$(invoke '{"function":"InitLedger","Args":[]}' 2>&1); echo "$OUT" >> "$LOG"
echo "$OUT" | grep -q "status:200" && pass "InitLedger submitted and committed" || fail "InitLedger did not report status:200"

echo "\$ peer chaincode query GetAllAssets" >> "$LOG"
OUT=$(peer chaincode query -C mychannel -n basic -c '{"Args":["GetAllAssets"]}' 2>&1); echo "$OUT" >> "$LOG"
echo "$OUT" | grep -q "asset1" && pass "GetAllAssets returned the initial assets" || fail "GetAllAssets did not return asset1"

step "6. Time three submits (each waits until the transaction is committed on the peer)"
TIMES=()
for i in 1 2 3; do
  ID="smoke$i"
  A=$(date +%s%N)
  OUT=$(invoke "{\"function\":\"CreateAsset\",\"Args\":[\"$ID\",\"blue\",\"5\",\"tom\",\"300\"]}" 2>&1)
  B=$(date +%s%N)
  echo "$OUT" >> "$LOG"
  echo "$OUT" | grep -q "status:200" || fail "CreateAsset $ID did not report status:200"
  MS=$(( (B - A) / 1000000 ))
  TIMES+=("$MS")
  say "submit $i: ${MS} ms"
done
RESULTS+=("PASS  3 timed submits: ${TIMES[*]} ms (includes peer CLI start-up, so the real gateway latency is a little lower)")

step "7. Read back what was committed"
OUT=$(peer chaincode query -C mychannel -n basic -c '{"Args":["ReadAsset","smoke3"]}' 2>&1); echo "$OUT" >> "$LOG"
echo "$OUT" | grep -q "tom" && pass "ReadAsset smoke3 returned the committed record" || fail "ReadAsset smoke3 failed"

say ""
say "================ SUMMARY ================"
for r in "${RESULTS[@]}"; do say "$r"; done
say ""
say "The network is still running. Stop it with:  cd $TN && ./network.sh down"
say "Log file: $LOG"

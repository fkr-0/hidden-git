#!/usr/bin/env bash
#!/bin/bash

# Script to manage HiddenGit services: Start, Stop, and Test soft-serve's response via its hidden .onion URL.
trap "echo 'Halting HiddenGit manifest...' && docker-compose down" INT TERM

# Cobble your trove's tomes and composes
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
COMPOSE_FILE="$DIR/docker-compose.yml"

NC='\033[0m' # No Color
echo_log() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

error_log() {
    RED='\033[0;31m'
    echo_log "${RED}ERROR: $1${NC}"
}

success_log() {
    GREEN='\033[0;32m'
    echo_log "${GREEN}$1${NC}"
}

# Starts the services and waits for a few seconds for services to initialize
start_services() {
    success_log "Starting HiddenGit services..."
    docker-compose up -d --build
    echo_log "Services starting, please wait..."
    sleep 10 # A small delay to let services to start
}

# Tries to request the front page of soft-serve's site to test its availability
test_service_availability() {
    local hidden_service_hostname
    hidden_service_hostname="$(docker-compose exec tor cat /var/lib/tor/hidden_service/hostname)"

    if [ -z "$hidden_service_hostname" ]; then
        error_log "Hidden service hostname not found."
        return 1
    else
        echo "Hidden service hostname is $hidden_service_hostname."

        # Curl to check the health, using a SOCKS5 proxy via Tor
        if curl --silent --socks5-hostname localhost:9050 --max-time 10 "http://$hidden_service_hostname" > /dev/null; then
            success_log "Soft-serve is reachable through its hidden Tor service."
        else
            error_log "Soft-serve is not reachable through its hidden Tor service."
            return 1
        fi
    fi
}

# Tests the SSH connection through the Tor client container
test_ssh_connection() {
    local hidden_service_hostname
    hidden_service_hostname="$(docker-compose exec tor cat /var/lib/tor/hidden_service/hostname)"

    if [ -z "$hidden_service_hostname" ]; then
        error_log "Hidden service hostname not found."
        return 1
    else
        echo "Hidden service hostname is $hidden_service_hostname."

        echo "Checking if SSH is reachable through the Tor client container..."
        if docker-compose exec tor-client torify ssh -o StrictHostKeyChecking=no -p 23231 softserve@$hidden_service_hostname "echo 'SSH connection successful'" > /dev/null; then
            success_log "SSH is reachable through the Tor client container."
        else
            error_log "SSH is not reachable through the Tor client container."
            return 1
        fi
    fi
}


# Stops all the related Docker containers
stop_services() {
    echo_log "Stopping all HiddenGit services..."
    docker-compose down
    echo_log "All services have been stopped."
}

# The main control flow starts here
case "$1" in
    start)
        start_services
        test_service_availability
        test_ssh_connection
        ;;
    stop)
        stop_services
        ;;
    build)
        docker-compose build
        ;;
    logs)
        docker-compose logs -f
        ;;
    *)
        echo "Usage: $0 {start|stop|build|logs}"
        exit 1
        ;;
esac

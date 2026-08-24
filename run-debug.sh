#!/usr/bin/env sh
# Run NeoStation in debug mode with environment variables from .env
# Usage: ./run-debug.sh
# Or with a custom env file: ./run-debug.sh -e .env.local

set -e

ENV_FILE=".env"

# Parse arguments
while [ $# -gt 0 ]; do
    case "$1" in
        -e|--env-file)
            ENV_FILE="$2"
            shift 2
            ;;
        *)
            break
            ;;
    esac
done

if [ ! -f "$ENV_FILE" ]; then
    echo "Error: Environment file not found: $ENV_FILE" >&2
    exit 1
fi

echo "Loading environment from: $ENV_FILE"
flutter run --dart-define-from-file="$ENV_FILE" "$@"

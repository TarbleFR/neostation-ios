#!/usr/bin/env sh
# Run NeoStation in release mode with environment variables from .env
# Usage: ./run-release.sh
# Or with a custom env file: ./run-release.sh -e .env.local

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
flutter run --release --dart-define-from-file="$ENV_FILE" "$@"

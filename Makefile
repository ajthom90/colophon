SIM ?= iPhone 17

gen:
	xcodegen generate

# pipefail: without it the pipeline exits with tail's status (always 0) and a
# BUILD FAILED would be reported green.
build-ios: gen
	set -o pipefail; xcodebuild -project Colophon.xcodeproj -scheme Colophon \
	  -destination 'platform=iOS Simulator,name=$(SIM)' \
	  -allowProvisioningUpdates build | tail -5

build-mac: gen
	set -o pipefail; xcodebuild -project Colophon.xcodeproj -scheme Colophon \
	  -destination 'platform=macOS' \
	  -allowProvisioningUpdates build | tail -5

test:
	cd Packages/ABSKit && swift test
	cd Packages/PlayerEngine && swift test
	cd Packages/LibraryCache && swift test

# pipefail: without it the pipeline exits with tail's status (always 0) and a
# red test suite would report green.
test-app: gen
	set -o pipefail; xcodebuild test -project Colophon.xcodeproj -scheme Colophon \
	  -destination 'platform=iOS Simulator,name=$(SIM)' \
	  -allowProvisioningUpdates 2>&1 | tail -8

server-up:
	docker compose -f devserver/docker-compose.yml up -d

server-down:
	docker compose -f devserver/docker-compose.yml down

seed:
	bash devserver/seed.sh

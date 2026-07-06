SIM ?= iPhone 17

gen:
	xcodegen generate

build-ios: gen
	xcodebuild -project Colophon.xcodeproj -scheme Colophon \
	  -destination 'platform=iOS Simulator,name=$(SIM)' build | tail -5

build-mac: gen
	xcodebuild -project Colophon.xcodeproj -scheme Colophon \
	  -destination 'platform=macOS' build | tail -5

test:
	cd Packages/ABSKit && swift test
	cd Packages/PlayerEngine && swift test

server-up:
	docker compose -f devserver/docker-compose.yml up -d

server-down:
	docker compose -f devserver/docker-compose.yml down

seed:
	bash devserver/seed.sh

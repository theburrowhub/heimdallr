.PHONY: build-daemon build-app test package-macos install-service dev

build-daemon:
	cd daemon && make build

build-app:
	cd flutter_app && flutter build macos --release

test:
	cd daemon && make test
	cd flutter_app && flutter test

package-macos: build-daemon build-app
	cp daemon/bin/auto-pr-daemon \
	  "flutter_app/build/macos/Build/Products/Release/auto_pr.app/Contents/MacOS/auto-pr-daemon"
	create-dmg \
	  --volname "auto-pr" \
	  --window-size 540 380 \
	  --icon-size 128 \
	  --app-drop-link 380 185 \
	  "dist/auto-pr.dmg" \
	  "flutter_app/build/macos/Build/Products/Release/auto_pr.app"

install-service: build-daemon
	./daemon/bin/auto-pr-daemon install

dev:
	cd daemon && make dev &
	cd flutter_app && flutter run -d macos

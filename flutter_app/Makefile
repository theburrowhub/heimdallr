.PHONY: build test gen run clean

gen:
	dart run build_runner build --delete-conflicting-outputs

build:
	flutter build macos --release

test:
	flutter test

run:
	flutter run -d macos

clean:
	flutter clean

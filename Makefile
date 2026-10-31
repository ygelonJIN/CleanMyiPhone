.PHONY: build run app clean

build:
	swift build

run: build
	swift run CleanMyiPhone $(ARGS)

app:
	chmod +x scripts/make-app.sh
	scripts/make-app.sh release

clean:
	rm -rf .build build .buildtmp

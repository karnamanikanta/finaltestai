.PHONY: build test

build:
    echo "Building..."
	gcc -o app main.c

test:
	echo "Running tests..."

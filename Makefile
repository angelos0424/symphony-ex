.PHONY: all fmt check dialyzer test

all: fmt check dialyzer test

fmt:
	mix format --check-formatted

check:
	mix credo --strict

dialyzer:
	mix dialyzer

test:
	mix test

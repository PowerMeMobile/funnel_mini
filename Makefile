.PHONY: all deps compile clean test xref doc check_plt build_plt clean_plt dialyze

NAME=funnel_mini
OTP_PLT=~/.otp.plt
PRJ_PLT=$(NAME).plt

all: generate

generate: compile xref
	@rm -rf ./rel/$(NAME)
	@./rebar generate
	$(info Rewrite RELEASES file with relative applications directory path)
	cd rel/funnel_mini && erl -eval '[ReleaseDir] = [D || D <- string:tokens(os:cmd("ls -1 releases/"), "\n"), D =/= "RELEASES", D =/= "start_erl.data"], ok = release_handler:create_RELEASES(".", "releases", "releases/"++ ReleaseDir ++"/funnel.rel", []).' -s init stop -noshell && cd -

compile: get-deps
	@./rebar compile

get-deps:
	@./rebar get-deps

update-deps:
	@./rebar update-deps

xref: compile
	@./rebar xref skip_deps=true

clean:
	@./rebar clean

dialyze: $(OTP_PLT) compile $(PRJ_PLT)
	@dialyzer --plt $(PRJ_PLT) -r ./subapps/*/ebin

$(OTP_PLT):
	@dialyzer --build_plt --output_plt $(OTP_PLT) --apps erts \
		kernel stdlib crypto mnesia sasl common_test eunit ssl \
		asn1 compiler syntax_tools inets

$(PRJ_PLT):
	@dialyzer --add_to_plt --plt $(OTP_PLT) --output_plt $(PRJ_PLT) \
	-r ./deps/*/ebin ./subapps/*/ebin

console:
	@./rel/$(NAME)/bin/funnel console

develop:
	@./rel/$(NAME)/bin/funnel develop

test: compile xref
	@./rebar skip_deps=true eunit

doc:
	@./rebar skip_deps=true doc

tags:
	@find . -name "*.[e,h]rl" -print | etags -

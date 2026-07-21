-module(concrete_page).

-callback init(Params :: map(), Server :: map()) ->
    {Component :: map(), Server :: map()}.

-callback template() -> TemplateFile :: string() | {inline, term()}.

-optional_callbacks([init/2]).

-module(gleam_codegen).
-include("gleam_records.hrl").
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([module/1]).

-define(erlang_module_operator(N),
        N =:= '+';  N =:= '-';  N =:= '*';  N =:= '/';  N =:= '+.'; N =:= '-.';
        N =:= '*.'; N =:= '/.'; N =:= '<='; N =:= '<' ; N =:= '>' ; N =:= '>=';
        N =:= '/').

% Holds state used in code generation.
-record(env, {uid = 0}).

module(#ast_module{name = Name, functions = Funs, exports = Exports}) ->
  PrefixedName = prefix_module(Name),
  C_name = cerl:c_atom(PrefixedName),
  C_exports =
    [ cerl:c_fname(module_info, 0)
    , cerl:c_fname(module_info, 1)
    | lists:map(fun export/1, Exports)
    ],
  C_definitions =
    [ module_info(PrefixedName, [])
    , module_info(PrefixedName, [cerl:c_var(item)])
    | lists:map(fun function/1, Funs)
    ],
  Attributes = [],
  Core = cerl:c_module(C_name, C_exports, Attributes, C_definitions),
  {ok, Core}.

export({Name, Arity}) when is_atom(Name), is_integer(Arity) ->
  cerl:c_fname(Name, Arity).

module_info(ModuleName, Params) when is_atom(ModuleName) ->
  Body = cerl:c_call(cerl:c_atom(erlang),
                     cerl:c_atom(get_module_info),
                     [cerl:c_atom(ModuleName) | Params]),
  C_fun = cerl:c_fun(Params, Body),
  C_fname = cerl:c_fname(module_info, length(Params)),
  {C_fname, C_fun}.

function(#ast_function{name = Name, args = Args, body = Body}) ->
  Env = #env{},
  Arity = length(Args),
  C_fname = cerl:c_fname(Name, Arity),
  C_args = lists:map(fun var/1, Args),
  {C_body, _} = expression(Body, Env),
  {C_fname, cerl:c_fun(C_args, C_body)}.

var(Atom) when is_atom(Atom) ->
  cerl:c_var(Atom).

map_with_env(Nodes, Env, F) ->
  Folder = fun(Node, {AccCore, AccEnv}) ->
             {NewCore, NewEnv} = F(Node, AccEnv),
             {[NewCore|AccCore], NewEnv}
           end,
  {Core, NewEnv} = lists:foldl(Folder, {[], Env}, Nodes),
  {lists:reverse(Core), NewEnv}.

map_clauses(Clauses, Env) ->
  map_with_env(Clauses, Env, fun clause/2).

map_expressions(Expressions, Env) ->
  map_with_env(Expressions, Env, fun expression/2).

expression(#ast_string{value = Value}, Env) when is_binary(Value) ->
  Chars = binary_to_list(Value),
  ByteSequence = lists:map(fun binary_string_byte/1, Chars),
  {cerl:c_binary(ByteSequence), Env};

expression(#ast_list{elems = Elems}, Env) ->
  {C_elems, NewEnv} = map_expressions(Elems, Env),
  {c_list(C_elems), NewEnv};

expression(#ast_tuple{elems = Elems}, Env) ->
  {C_elems, NewEnv} = map_expressions(Elems, Env),
  {cerl:c_tuple(C_elems), NewEnv};

expression(#ast_atom{value = Value}, Env) when is_atom(Value) ->
  {cerl:c_atom(Value), Env};

expression(#ast_int{value = Value}, Env) when is_integer(Value) ->
  {cerl:c_int(Value), Env};

expression(#ast_float{value = Value}, Env) when is_float(Value) ->
  {cerl:c_float(Value), Env};

expression(#ast_var{name = Name}, Env) when is_atom(Name) ->
  {cerl:c_var(Name), Env};

expression(#ast_local_call{name = '::', args = [Head, Tail]}, Env) ->
  {C_head, Env1} = expression(Head, Env),
  {C_tail, Env2} = expression(Tail, Env1),
  {cerl:c_cons(C_head, C_tail), Env2};

expression(#ast_local_call{name = Name, args = Args}, Env)
when ?erlang_module_operator(Name) ->
  ErlangName = erlang_operator_name(Name),
  expression(#ast_call{module = erlang, name = ErlangName, args = Args}, Env);

expression(#ast_local_call{name = Name, args = Args}, Env) ->
  C_fname = cerl:c_fname(Name, length(Args)),
  {C_args, NewEnv} = map_expressions(Args, Env),
  {cerl:c_apply(C_fname, C_args), NewEnv};

expression(#ast_call{module = Mod, name = Name, args = Args}, Env) ->
  C_module = cerl:c_atom(prefix_module(Mod)),
  C_name = cerl:c_atom(Name),
  {C_args, NewEnv} = map_expressions(Args, Env),
  {cerl:c_call(C_module, C_name, C_args), NewEnv};

expression(#ast_assignment{name = Name, value = Value, then = Then}, Env) ->
  C_var = cerl:c_var(Name),
  {C_value, Env1} = expression(Value, Env),
  {C_then, Env2} = expression(Then, Env1),
  {cerl:c_let([C_var], C_value, C_then), Env2};

expression(#ast_adt{name = Name, elems = []}, Env) ->
  {cerl:c_atom(adt_name_to_atom(atom_to_list(Name))), Env};

expression(#ast_adt{name = Name, meta = Meta, elems = Elems}, Env) ->
  AtomValue = adt_name_to_atom(atom_to_list(Name)),
  Atom = #ast_atom{meta = Meta, value = AtomValue},
  expression(#ast_tuple{elems = [Atom | Elems]}, Env);

expression(#ast_case{subject = Subject, clauses = Clauses}, Env) ->
  {C_subject, Env1} = expression(Subject, Env),
  {C_clauses, Env2} = map_clauses(Clauses, Env1),
  {cerl:c_case(C_subject, C_clauses), Env2};

% We generate a unique variable name for each hole to prevent
% the BEAM thinking two holes are the same.
expression(hole, #env{uid = UID} = Env) ->
  NewEnv = Env#env{uid = UID + 1},
  Name = list_to_atom([$_ | integer_to_list(UID)]),
  {cerl:c_var(Name), NewEnv};

expression(Expressions, Env) when is_list(Expressions) ->
  {C_exprs, Env1} = map_expressions(Expressions, Env),
  [Head | Tail] = lists:reverse(C_exprs),
  C_seq = lists:foldl(fun cerl:c_seq/2, Head, Tail),
  {C_seq, Env1}.

clause(#ast_clause{pattern = Pattern, value = Value}, Env) ->
  {C_pattern, Env1} = expression(Pattern, Env),
  {C_value, Env2} = expression(Value, Env1),
  C_clause = cerl:c_clause([C_pattern], C_value),
  {C_clause, Env2}.

adt_name_to_atom(Chars) ->
  case string:uppercase(Chars) =:= Chars of
    true -> Chars;
    false -> adt_name_to_atom(Chars, [])
  end.

adt_name_to_atom([C | Chars], []) when C >= $A, C =< $Z ->
  adt_name_to_atom(Chars, [C + 32]);
adt_name_to_atom([C | Chars], Acc) when C >= $A, C =< $Z ->
  adt_name_to_atom(Chars, [C + 32, $_ | Acc]);
adt_name_to_atom([C | Chars], Acc) ->
  adt_name_to_atom(Chars, [C | Acc]);
adt_name_to_atom([], Acc) ->
  list_to_atom(lists:reverse(Acc)).

erlang_operator_name('/') -> 'div';
erlang_operator_name('+.') -> '+';
erlang_operator_name('-.') -> '-';
erlang_operator_name('*.') -> '*';
erlang_operator_name('/.') -> '/';
erlang_operator_name('<=') -> '=<';
erlang_operator_name(Name) -> Name.

c_list(Elems) ->
  Rev = lists:reverse(Elems),
  lists:foldl(fun cerl:c_cons/2, cerl:c_nil(), Rev).

binary_string_byte(Char) ->
  cerl:c_bitstr(cerl:c_int(Char),
                cerl:c_int(8),
                cerl:c_int(1),
                cerl:c_atom(integer),
                c_list([cerl:c_atom(unsigned), cerl:c_atom(big)])).

prefix_module(erlang) -> erlang;
prefix_module(Name) when is_atom(Name) -> list_to_atom("Gleam." ++ atom_to_list(Name)).
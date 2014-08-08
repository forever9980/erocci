%%% @author Jean Parpaillon <jean.parpaillon@free.fr>
%%% @copyright (C) 2013, Jean Parpaillon
%%% 
%%% This file is provided to you under the Apache License,
%%% Version 2.0 (the "License"); you may not use this file
%%% except in compliance with the License.  You may obtain
%%% a copy of the License at
%%% 
%%%   http://www.apache.org/licenses/LICENSE-2.0
%%% 
%%% Unless required by applicable law or agreed to in writing,
%%% software distributed under the License is distributed on an
%%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%%% KIND, either express or implied.  See the License for the
%%% specific language governing permissions and limitations
%%% under the License.
%%% 
%%% @doc use EEP1108 format ofr JSON internal representation
%%% http://www.erlang.org/eeps/eep-0018.html
%%%
%%% @end
%%% Created : 30 Aug 2013 by Jean Parpaillon <jean.parpaillon@free.fr>
-module(occi_renderer_xml).
-compile({parse_transform, lager_transform}).

-behaviour(occi_renderer).

-include("occi.hrl").
-include("occi_xml.hrl").
-include_lib("erim/include/exmpp_xml.hrl").

-export([render/2,
	 to_xmlel/2]).

-define(declared_occi_ns, {?occi_ns, none}).
-define(declared_xlink_ns, {?xlink_ns, "xl"}).

%%%
%%% API
%%%
render(#occi_node{}=Node, Env) ->
    {[render_xml(to_xmlel(Node, Env)), "\n"], Env}.

to_xmlel(#occi_node{id=Id, type=occi_resource, data=Res}, Env) ->
    E = make_ns([?declared_occi_ns, ?declared_xlink_ns],
		exmpp_xml:element(
		  ?occi_ns, resource,
		  [exmpp_xml:attribute(<<"id">>, occi_uri:to_binary(Id, Env)),
		   exmpp_xml:attribute(<<"title">>, occi_resource:get_attr_value(Res, 'occi.core.title'))], 
		  [make_cid(kind, occi_resource:get_cid(Res))])),
   lists:foldl(
     fun (#uri{}=Link, Acc) -> 
	     render_rel(Acc, link, Link, Env);
	 (#occi_node{id=LinkId, data=Link}, Acc) ->
	     exmpp_xml:append_child(Acc, make_link(LinkId, Link, Env))
     end, 
     lists:foldl(
       fun (Attr, Acc) -> render_attribute(Acc, Attr, Env) end, 
       sets:fold(
	 fun (Mixin, Acc) -> render_cid(Acc, mixin, Mixin) end,
	 E, occi_resource:get_mixins(Res)),
       occi_resource:get_attributes(Res)),
     occi_resource:get_links(Res));

to_xmlel(#occi_node{id=Id, type=occi_link, data=Link}, Env) ->
    make_ns([?declared_occi_ns, ?declared_xlink_ns], make_link(Id, Link, Env));

to_xmlel(#occi_node{type=capabilities, data={Kinds, Mixins, Actions}}, Env) ->
    Children = lists:map(fun (X) -> render_kind(X, Env) end, Kinds)
	++ lists:map(fun (X) -> render_mixin(X, Env) end, Mixins)
	++ lists:map(fun (X) -> render_action(X, Env) end, Actions),
    make_ns([?declared_occi_ns],
	    exmpp_xml:element(?occi_ns, capabilities, [], Children));

to_xmlel(#occi_node{type=capabilities, data=Mixin}, Env) ->
    render_mixin(Mixin, Env);

to_xmlel(#occi_node{type=occi_collection, objid=Id, data=Coll}, Env) ->
    Attrs = case Id of
		#occi_cid{} -> 
		    [ exmpp_xml:attribute(<<"scheme">>, Id#occi_cid.scheme),
		      exmpp_xml:attribute(<<"term">>, Id#occi_cid.term) ];
		_ -> []
	    end,
    make_ns([?declared_occi_ns, ?declared_xlink_ns],
	    exmpp_xml:element(
	      ?occi_ns, collection, Attrs,
	      [exmpp_xml:element(
		 ?occi_ns, entity,
		 [exmpp_xml:attribute(?xlink_ns, <<"href">>, occi_uri:to_binary(Uri, Env))], []) || 
		  Uri <- occi_collection:get_entities(Coll) ])).

%%%
%%% Private
%%%
make_link(Id, #occi_link{}=Link, Env) ->
    C = [make_cid(kind, occi_link:get_cid(Link)),
	 make_attribute('occi.core.target', occi_link:get_target(Link), Env)],
    C2 = case occi_link:get_source(Link) of
	     undefined -> C;
	     #uri{}=Uri -> [make_attribute('occi.core.source', Uri, Env) | C]
	 end,
    A = case occi_link:get_attr_value(Link, 'occi.core.title') of
	    undefined -> [];
	     V -> [exmpp_xml:attribute(<<"title">>, V)]
	end,
    E = exmpp_xml:element(?occi_ns, link,
			  [exmpp_xml:attribute(<<"id">>, occi_uri:to_string(Id, Env)) | A],
			  C2),
    E2 = orddict:fold(
	   fun (_Key, Attr, Acc) -> 
		   render_attribute(Acc, Attr, Env) 
	   end, E, Link#occi_link.attributes),
    sets:fold(
      fun (Mixin, Acc) -> 
	      render_cid(Acc, mixin, Mixin) 
      end, E2, occi_link:get_mixins(Link)).

render_kind(#occi_kind{}=Kind, Env) ->
    E = render_category(exmpp_xml:element(?occi_ns, kind), Kind, Env),
    E2 = render_parent(E, occi_kind:get_parent(Kind)),
    render_attr_specs(E2, occi_kind:get_attr_list(Kind)).

render_mixin(#occi_mixin{}=Mixin, Env) ->
    E = render_category(exmpp_xml:element(?occi_ns, mixin), Mixin, Env),
    E2 = render_depends(E, occi_mixin:get_depends(Mixin)),
    E3 = render_applies(E2, occi_mixin:get_applies(Mixin)),
    render_attr_specs(E3, occi_mixin:get_attr_list(Mixin)).

render_category(#xmlel{}=E, #occi_kind{location=#uri{}=Uri}=Kind, Env) ->
    render_category(E, 
		    occi_kind:get_scheme(Kind),
		    occi_kind:get_term(Kind),
		    occi_kind:get_title(Kind),
		    occi_uri:to_binary(Uri, Env));

render_category(#xmlel{}=E, #occi_mixin{location=#uri{}=Uri}=Mixin, Env) ->
    render_category(E, 
		    occi_mixin:get_scheme(Mixin),
		    occi_mixin:get_term(Mixin),
		    occi_mixin:get_title(Mixin),
		    occi_uri:to_binary(Uri, Env)).

render_category(E, Scheme, Term, Title, Uri) ->
    set_attributes(E, [{<<"scheme">>, Scheme}, {<<"term">>, Term}, 
		       {<<"title">>, Title}, {<<"location">>, Uri}]).

render_action(#occi_action{location=Uri}=Action, Env) ->
    Attrs = [{<<"scheme">>, occi_action:get_scheme(Action)},
	     {<<"term">>, occi_action:get_term(Action)},	     
	     {<<"title">>, occi_action:get_title(Action)},
	     {<<"location">>, occi_uri:to_binary(Uri, Env)}],
    E = set_attributes(exmpp_xml:element(?occi_ns, action), Attrs),
    render_attr_specs(E, occi_action:get_attr_list(Action)).

render_cid(E, _, undefined) ->
    E;
render_cid(E, Name, #occi_cid{}=Cid) ->
    exmpp_xml:append_child(E, make_cid(Name, Cid)).

make_cid(Name, #occi_cid{scheme=Scheme, term=Term}) ->
    exmpp_xml:element(?occi_ns, Name, 
		      [exmpp_xml:attribute(<<"scheme">>, Scheme),
		       exmpp_xml:attribute(<<"term">>, Term)],
		      []).

render_rel(E, _, undefined, _) ->
    E;
render_rel(E, Name, #uri{}=Uri, Env) ->
    exmpp_xml:append_child(E, make_rel(Name, Uri, Env)).

make_rel(Name, #uri{}=Uri, Env) ->
    exmpp_xml:element(?occi_ns, Name, 
		      [exmpp_xml:attribute(?xlink_ns, <<"href">>, occi_uri:to_binary(Uri, Env))],
		      []).

render_parent(E, Cid) ->
    render_cid(E, parent, Cid).

render_depends(E, []) ->
    E;
render_depends(E, [#occi_cid{}=Cid|Tail]) ->
    render_depends(
      render_cid(E, depends, Cid), Tail).

render_applies(E, []) ->
    E;
render_applies(E, [#occi_cid{}=Cid|Tail]) ->
    render_applies(
      render_cid(E, applies, Cid), Tail).

render_attr_specs(E, []) ->
    E;
render_attr_specs(E, [#occi_attr{}=A|Tail]) ->
    render_attr_specs(
      exmpp_xml:append_child(E, make_attr_spec(A)), Tail).

make_attr_spec(#occi_attr{}=A) ->
    L = [exmpp_xml:attribute(<<"type">>, occi_attribute:get_type_id(A))],
    L2 = case occi_attribute:is_immutable(A) of
	     false -> L;
	     true -> [exmpp_xml:attribute(<<"immutable">>, true) | L]
	 end,
    L3 = case occi_attribute:is_required(A) of
	     false -> L2;
	     true -> [exmpp_xml:attribute(<<"use">>, "required") | L2]
	 end,
    L4 = case occi_attribute:get_default(A) of
	     undefined -> L3;
	     D -> [exmpp_xml:attribute(<<"default">>, D) | L3]
	 end,
    L5 = case occi_attribute:get_title(A) of
	     undefined -> L4;
	     T -> [exmpp_xml:attribute(<<"title">>, T) | L4]
	 end,
    L6 = [exmpp_xml:attribute(<<"name">>, occi_attribute:get_id(A)) | L5],
    exmpp_xml:element(?occi_ns, attribute, L6, []).

render_attribute(E, #occi_attr{value=undefined}, _) ->
    E;
render_attribute(E, #occi_attr{id='occi.core.id'}, _) ->
    E;
render_attribute(E, #occi_attr{}=Attr, Env) ->
    exmpp_xml:append_child(
      E, 
      make_attribute(occi_attribute:get_id(Attr), occi_attribute:get_value(Attr), Env)).

make_attribute(Name, #uri{}=Uri, Env) ->
    exmpp_xml:element(?occi_ns, attribute, 
		      [exmpp_xml:attribute(<<"name">>, Name),
		       exmpp_xml:attribute(?xlink_ns, <<"href">>, occi_uri:to_binary(Uri, Env))],
		      []);
make_attribute(Name, Value, Env) ->
    exmpp_xml:element(?occi_ns, attribute, 
		      [exmpp_xml:attribute(<<"name">>, Name),
		       exmpp_xml:attribute(<<"value">>, render_attr_value(Value, Env))],
		      []).

set_attributes(#xmlel{}=E, []) ->
    E;
set_attributes(#xmlel{}=E, [{_Name, undefined}|Tail]) ->
    set_attributes(E, Tail);
set_attributes(#xmlel{}=E, [{Name, Value}|Tail]) ->
    set_attributes(exmpp_xml:set_attribute(E, Name, Value), Tail).

render_xml(#xmlel{}=Doc) ->
    exmpp_xml:document_to_iolist(
      exmpp_xml:indent_document(Doc, <<"  ">>)).

render_attr_value(Val, _) when is_float(Val) ->
    io_lib:format("~p", [Val]);
render_attr_value(#uri{}=Val, Env) ->
    occi_uri:to_string(Val, Env);
render_attr_value(Val, _) ->
    Val.

make_ns([], #xmlel{}=E) ->
    E;
make_ns([{NS, Prefix}|Tail], #xmlel{}=E) ->
    make_ns(Tail, exmpp_xml:declare_ns_here(E, NS, Prefix)).

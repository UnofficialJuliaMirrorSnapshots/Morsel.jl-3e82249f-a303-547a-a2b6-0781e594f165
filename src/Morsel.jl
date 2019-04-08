module Morsel

using Compat,
      HttpServer,
      HttpCommon,
      Meddle,
      Compat

import Base.start

export App,
       app,
       route,
       namespace,
       with,
       get,
       post,
       put,
       update,
       delete,
       start,
       urlparam,
       routeparam,
       param,
       unsafestring,
       redirect,

       # from HttpCommon
       GET,
       POST,
       PUT,
       UPDATE,
       DELETE,
       OPTIONS,
       HEAD,

       # from Routes
       match_route_handler

include("Routes.jl")

# This produces a dictionary that maps each type of request (GET, POST, etc.)
# to a `RoutingTable`, which is an alias to the `Tree` datatype specified in
# `Trees.jl`.
routing_tables() = (HttpMethodBitmask => RoutingTable)[method => RoutingTable()
                                            for method in HttpMethodBitmasks]

# An 'App' is simply a dictionary linking each HTTP method to a `RoutingTable`.
# The default constructor produces an empty `RoutingTable` for members of
# `HttpMethods`.
#
type App
    routes::Dict{HttpMethodBitmask, RoutingTable}
    state::Dict{Any,Any}
end
function app()
    App(routing_tables(), Dict{Any,Any}())
end

# This defines a route and adds it to the `app.routes` dictionary. As HTTP
# methods are bitmasked integers they can be combined using the bitwise or
# operator, e.g. `GET | POST` refers to a `GET` method and a `POST` method.
#
# Example:
#
#   function hello_world(req, res)
#       "Hello, world!"
#   end
#   route(hello_world, GET | POST, "/hello/world")
#
# Or using do syntax:
#
#   route(app, GET | POST, "/hello/world") do req, res
#       "Hello, world"
#   end
#
function route(handler::Function, app::App, methods::Int, path::String)
    prefix    = get(app.state, :routeprefix, "")
    withstack = get(app.state, :withstack, Midware[])
    handle    = handler
    if length(withstack) > 0
        stack  = middleware(withstack..., Midware( (req::MeddleRequest, res::Response) -> prepare_response(handler(req, res), req, res) ))
        handle = (req::MeddleRequest, res::Response) -> Meddle.handle(stack, req, res)
    end
    for method in HttpMethodBitmasks
        methods & method == method && register!(app.routes[method], prefix * path, handle)
    end
    app
end
route(a::App, m::Int, p::String, h::Function) = route(h, a, m, p)

function namespace(thunk::Function, app::App, prefix::String)
    beforeprefix = get(app.state, :routeprefix, "")
    app.state[:routeprefix] = beforeprefix * prefix
    thunk(app)
    app.state[:routeprefix] = beforeprefix
    app
end

namespace(thunk::Function, app::App, prefix::String, mid::Union(Midware,MidwareStack)...) = with((app) -> namespace(thunk, app, prefix), app, mid...)

function with(thunk::Function, app::App, stack::MidwareStack)
    withstack = get(app.state, :withstack, Midware[])
    beforelen = length(withstack)
    for mid in stack
      push!(withstack, mid)
    end
    app.state[:withstack] = withstack
    thunk(app)
    app.state[:withstack] = withstack[1:beforelen]
    app
end

with(thunk::Function, app::App, mid::Midware...) = with(thunk, app, middleware(mid...))

import Base.get

# These are shortcut functions for common calls to `route`.
# e.g `get` calls `route` with a `GET` as the method parameter.
#
get(h::Function, a::App, p::String)    = route(h, a, GET, p)
post(h::Function, a::App, p::String)   = route(h, a, POST, p)
put(h::Function, a::App, p::String)    = route(h, a, PUT, p)
update(h::Function, a::App, p::String) = route(h, a, UPDATE, p)
delete(h::Function, a::App, p::String) = route(h, a, DELETE, p)

sanitize(input::String) = replace(input,r"</?[^>]*>|</?|>","")
sanitize(x) = x

function validatedvalue(value::Any, validator::Function)
    value == nothing && return nothing
    if is(validator, string)
        value = sanitize(value)
    end
    validator(value)
end

function safelyaccess(req::MeddleRequest, stateKey::Symbol, valKey::Any, validator::Function)
    haskey(req.state, stateKey) ? validatedvalue(get(req.state[stateKey], valKey, nothing), validator) : nothing
end

# validator for getting unsafe ( raw ) input
#
unsafestring(input::String) = input

# Safe accessors for URL parameters, route parameters and POST data
#
function urlparam(req::MeddleRequest, key::String, validator::Function=string)
    safelyaccess(req, :url_params, key, validator)
end
function routeparam(req::MeddleRequest, key::String, validator::Function=string)
    safelyaccess(req, :route_params, key, validator)
end
function param(req::MeddleRequest, key::String, validator::Function=string)
    safelyaccess(req, :data, key, validator)
end
# support symbols...
function urlparam(req::MeddleRequest, key::Symbol, validator::Function=string)
    urlparam(req, string(key), validator)
end
function routeparam(req::MeddleRequest, key::Symbol, validator::Function=string)
    routeparam(req, string(key), validator)
end
function param(req::MeddleRequest, key::Symbol, validator::Function=string)
    param(req, string(key), validator)
end

# `prepare_response` simply sets the data field of the `Response` to the input
# string `s` and calls the middleware's `respond` function.
#
function prepare_response(data::String, req::MeddleRequest, res::Response)
    res.data = data
    respond(req, res)
end
function prepare_response(status::Int, req::MeddleRequest, res::Response)
    res.status = status
    respond(req, res)
end
function prepare_response(data::@compat(Tuple{Int, String}), req::MeddleRequest, res::Response)
    res.status = data[1]
    res.data = data[2]
    respond(req, res)
end
prepare_response(r::Response, req::MeddleRequest, res::Response) = respond(req, r)

function redirect(r::Response, location::String, status::Int)
  r.status = status
  r.headers["Location"] = location

  r
end

redirect(r::Response, location::String) = redirect(r, location, 302) # status 302, Moved Temporarily

# `start` uses to `HttpServer.jl` and `Meddle.jl` packages to launch a webserver
# running `app` on the desired `port`.
#
# This is a blocking function.  Anything that appears after it in the source
# file will not run.
#
function start(app::App, port::Int)

    MorselApp = Midware() do req::MeddleRequest, res::Response
        path = String["/"]
        for comp in split(req.state[:resource], '/')
            !isempty(comp) && push!(path, comp)
        end
        methodizedRouteTable = app.routes[HttpMethodNameToBitmask[req.http_req.method]]
        handler, params = match_route_handler(methodizedRouteTable, path)
        for (k,v) in params
          req.params[symbol(k)] = v
        end
        if handler != nothing
            return prepare_response(handler(req, res), req, res)
        end
        respond(req, Response(404))
    end

    stack = middleware(DefaultHeaders, URLDecoder, CookieDecoder, BodyDecoder, MorselApp)
    http = HttpHandler((req, res) -> Meddle.handle(stack, MeddleRequest(req,Dict{Symbol,Any}(),Dict{Symbol,Any}()), res))
    http.events["listen"] = (port) -> println("Morsel is listening on $port...")

    server = Server(http)
    run(server, port)
end

end # module Morsel

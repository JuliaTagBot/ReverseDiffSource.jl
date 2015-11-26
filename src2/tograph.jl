##########  Parameterized type to ease AST exploration  ############
type ExH{H}
  head::Symbol
  args::Vector
  typ::Any
end
toExH(ex::Expr) = ExH{ex.head}(ex.head, ex.args, ex.typ)
toExpr(ex::ExH) = Expr(ex.head, ex.args...)

typealias ExEqual    ExH{:(=)}
typealias ExDColon   ExH{:(::)}
typealias ExColon    ExH{:(:)}
typealias ExPEqual   ExH{:(+=)}
typealias ExMEqual   ExH{:(-=)}
typealias ExTEqual   ExH{:(*=)}
typealias ExTrans    ExH{symbol("'")}
typealias ExCall     ExH{:call}
typealias ExBlock    ExH{:block}
typealias ExLine     ExH{:line}
typealias ExVcat     ExH{:vcat}
typealias ExVect     ExH{:vect}
typealias ExCell1d   ExH{:cell1d}
typealias ExCell     ExH{:cell1d}
typealias ExFor      ExH{:for}
typealias ExRef      ExH{:ref}
typealias ExIf       ExH{:if}
typealias ExComp     ExH{:comparison}
typealias ExDot      ExH{:.}
typealias ExTuple    ExH{:tuple}
typealias ExReturn   ExH{:return}
typealias ExBody     ExH{:body}
typealias ExQuote    ExH{:QuoteNode}

isSym(ex)   = isa(ex, Symbol)
isDot(ex)   = isa(ex, Expr) && ex.head == :.   # && isa(ex.args[1], Symbol)
isRef(ex)   = isa(ex, Expr) && ex.head == :ref # && isa(ex.args[1], Symbol)

function modenv(m::Module=current_module())
  function lookup(s::Symbol)
    isdefined(m, s) || return (false, nothing, nothing, nothing)
    (true, eval(m,s), isconst(m,s), nothing)
  end
end

# graph is to be created
# entry point for top level (Graph is created)
function tograph(ex::Expr, env=modenv())
  g, ops = tograph(ex, env, Graph())
  g.ops  = ops
  g
end
# tograph(m::Method, env)

# graph is pre-existing
function blockparse(ex::ExFor, env, g)
  # new scope, new env w/ local symbols dict
  # returns ForBlock
  # env with indexing variables added ?
  tograph(ex, env, g, isclosure=true)
end

function blockparse(ex::ExIf, env, g)
  # same scope, same env
  # returns IfBlock
end

# both above call....

# entry point for top level
function tograph(ex, env, g::Graph, isclosure=false)  # env = modenv  # ex = :( z.x )
  # isclosure = true  => new loc have no symbol in g
  # isclosure = false => new loc have a symbol in g

  symbols = isclosure ? copy(g.symbols) : g.symbols
  ops     = Vector{Op}()

  add!(l::Loc) = (push!(g.locs,l) ; l)
  add!(o::Op)  = (push!(ops, o) ; o)

  # AST exploration functions
  explore(ex::Any)       = error("[tograph] unmanaged type $ex ($(typeof(ex)))")
  explore(ex::Expr)      = explore(toExH(ex))
  explore(ex::ExH)       = error("[tograph] unmanaged expr type $(ex.head) in ($ex)")

  explore(ex::ExLine)         = nothing     # ignore line info
  explore(ex::LineNumberNode) = nothing     # ignore line info

  explore(ex::QuoteNode) = add!(CLoc(ex.value))  # consider as constant

  explore(ex::ExReturn)  = explore(ex.args[1]) # focus on returned statement

  explore(ex::ExVcat)    = explore(Expr(:call, :vcat, ex.args...) )  # translate to vcat() call, and explore
  explore(ex::ExVect)    = explore(Expr(:call, :vcat, ex.args...) )  # translate to vcat() call, and explore
  explore(ex::ExCell1d)  = explore(Expr(:call, :(Base.cell_1d), ex.args...) )  # translate to cell_1d() call, and explore
  explore(ex::ExTrans)   = explore(Expr(:call, :transpose, ex.args[1]) )  # translate to transpose() and explore
  explore(ex::ExColon)   = explore(Expr(:call, :colon, ex.args...) )  # translate to colon() and explore
  explore(ex::ExTuple)   = explore(Expr(:call, :tuple, ex.args...) )  # translate to tuple() and explore
  explore(ex::ExComp)    = explore(Expr(:call, ex.args[2], ex.args[1], ex.args[3]) )

  explore(ex::ExPEqual)  = (args = ex.args ; explore( Expr(:(=), args[1], Expr(:call, :+, args[1], args[2])) ) )
  explore(ex::ExMEqual)  = (args = ex.args ; explore( Expr(:(=), args[1], Expr(:call, :-, args[1], args[2])) ) )
  explore(ex::ExTEqual)  = (args = ex.args ; explore( Expr(:(=), args[1], Expr(:call, :*, args[1], args[2])) ) )

  explore(ex::Real)      = add!(CLoc(ex))

  explore(ex::ExBlock)   = map( explore, ex.args )[end]
  explore(ex::ExBody)    = map( explore, ex.args )[end]

  # explore(ex::ExComp)    = addnode!(g, NComp(ex.args[2], [explore(ex.args[1]), explore(ex.args[3])]))

  explore(ex::ExDot)     = explore(Expr(:call, :getfield, ex.args...))
  explore(ex::ExRef)     = explore(Expr(:call, :getindex, ex.args...))

  function explore(ex::Symbol)
      haskey(symbols, ex) && return symbols[ex]
      # if not known, then it is a new external
      isdef, val, iscst, _ = env(ex)
      isdef || error("symbol $ex is not defined")

      nloc = iscst ? CLoc(val) : ELoc(val)
      symbols[ex] = nloc
      add!(nloc)  # return Loc
  end

  function explore(ex::ExCall) # TODO :  treat func that return several values
      floc  = explore(ex.args[1])
      esf   = floc.val

      largs = map(explore, ex.args[2:end]) # explore arguments
      val = (esf)([x.val for x in largs]...)

      if sprint(show, esf)[end] == '!' # mutating ? TODO : generalize with rules
          nloc = largs[1]
          loctype(nloc)==:external &&
            error("attempt to modify an external variable in $(toExpr(ex))")
      elseif esf in [getindex, getfield] # propagate type of object to result
          # if module mark as external directly
          ntyp = largs[1].typ==Module ? :external : loctype(largs[1])
          nloc = Loc{ntyp}(val)
          add!(nloc)
      else
          nloc = RLoc(val)
          add!(nloc)
      end

      add!( Op(floc, largs, [nloc;]) )
      nloc  # return Loc of result
  end

  function explore(ex::ExEqual) #  ex = toExH(:(a = sin(2)))
    lhs, rhs = ex.args

    if isa(lhs, Symbol)
      if haskey(symbols, lhs)
        lloc = symbols[lhs]
        loctype(lloc)==:external &&
        error("attempt to modify an external variable in $(toExpr(ex))")
      else
        isdef, val = env(lhs)
        isdef && error("attempt to modify an external variable in $(toExpr(ex))")
      end

      rloc = explore(rhs)

      if isbits(rloc.typ)  # bitstype => '=' is a copy
        nloc = RLoc(rloc.val)
        floc = CLoc(copy)
        add!(floc)
        add!( Op(floc, [rloc;], [nloc;]) )
        add!(nloc)
      else  # array or composite type => '=' is a reference
        nloc = rloc
      end
      symbols[lhs] = nloc
      return nloc

    elseif isRef(lhs)   # x[i] = ....
      explore( Expr(:call, :setindex!, lhs.args[1], rhs, lhs.args[2:end]...) )
      return nothing  # TODO : should return the Array

    elseif isDot(lhs)   # x.field = ....
      explore( Expr(:call, :setfield!, lhs.args[1], lhs.args[2], rhs) )
      return nothing  # TODO : should return the composite type

    else
        error("[tograph] $(toExpr(ex)) not allowed on LHS of assigment")
    end

    nothing
      # catch getindex, etc. qualified by a module
      # sf2 = if isa(sf, Expr) && sf.head == :. && isa(sf.args[2], QuoteNode)
      #         sf.args[2].value
      #       else
      #         nothing
      #       end
  end

  exitloc = explore(ex)

  # id is 'nothing' for unnassigned last statement
  exitloc != nothing && ( symbols[EXIT_SYM] = exitloc )

    # # Resolve external symbols that are Functions, DataTypes or Modules
    # # and turn them into constants
    # for en in filter(n -> isa(n, NExt) & !in(n.main, svars) , keys(g.exti))
    #     if isdefined(evalmod, en.main)  # is it defined
    #         tv = evalmod.eval(en.main)
    #         isa(tv, TypeConstructor) && error("[tograph] TypeConstructors not supported: $ex $(tv), use DataTypes")
    #         if isa(tv, DataType) || isa(tv, Module) || isa(tv, Function)
    #             delete!(g.exti, en)
    #             nc = addnode!(g, NConst( tv ))
    #             fusenodes(g, nc, en)
    #         end
    #     end
    # end

  g, ops  # return graph and ops created
end

#
# function indexspec(nv, as)
#     p  = ExNode[]
#     for (i,na) in enumerate(as)
#         if length(as)==1 # single dimension
#             ns = addgraph!(:( length(x) ), g, @compat Dict(:x => nv) )
#         else # several dimensions
#             ns = addgraph!(:( size(x, $i) ), g, @compat Dict(:x => nv) )
#         end
#
#         na==:(:) && (na = Expr(:(:), 1, :end) )  # replace (:) with (1:end)
#
#         # explore the dimension expression
#         nsvars = union(svars, collect(syms(g.seti)))
#         ng = tograph(na, evalmod, nsvars)
#
#         # find mappings for onodes, including :end
#         vmap = Dict()
#         for (k, sym) in ng.exti.kv
#             vmap[sym] = sym == :end ? ns : explore(sym)
#         end
#
#         nd = addgraph!(ng, g, vmap)
#         push!(p, nd)
#     end
#     p
# end
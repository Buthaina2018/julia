# This file is a part of Julia. License is MIT: https://julialang.org/license

## MersenneTwister

const MTCacheLength = dsfmt_get_min_array_size()

mutable struct MersenneTwister <: AbstractRNG
    seed::Vector{UInt32}
    state::DSFMT_state
    vals::Vector{Float64}
    idx::Int

    function MersenneTwister(seed, state, vals, idx)
        length(vals) == MTCacheLength &&  0 <= idx <= MTCacheLength ||
            throw(DomainError((length(vals), idx),
                      "`length(vals)` and `idx` must be consistent with $MTCacheLength"))
        new(seed, state, vals, idx)
    end
end

MersenneTwister(seed::Vector{UInt32}, state::DSFMT_state) =
    MersenneTwister(seed, state, zeros(Float64, MTCacheLength), MTCacheLength)

"""
    MersenneTwister(seed)

Create a `MersenneTwister` RNG object. Different RNG objects can have their own seeds, which
may be useful for generating different streams of random numbers.

# Examples
```jldoctest
julia> rng = MersenneTwister(1234);

julia> x1 = rand(rng, 2)
2-element Array{Float64,1}:
 0.590845
 0.766797

julia> rng = MersenneTwister(1234);

julia> x2 = rand(rng, 2)
2-element Array{Float64,1}:
 0.590845
 0.766797

julia> x1 == x2
true
```
"""
MersenneTwister(seed) = srand(MersenneTwister(Vector{UInt32}(), DSFMT_state()), seed)

function copy!(dst::MersenneTwister, src::MersenneTwister)
    copy!(resize!(dst.seed, length(src.seed)), src.seed)
    copy!(dst.state, src.state)
    copy!(dst.vals, src.vals)
    dst.idx = src.idx
    dst
end

copy(src::MersenneTwister) =
    MersenneTwister(copy(src.seed), copy(src.state), copy(src.vals), src.idx)

==(r1::MersenneTwister, r2::MersenneTwister) =
    r1.seed == r2.seed && r1.state == r2.state && isequal(r1.vals, r2.vals) && r1.idx == r2.idx


## Low level API for MersenneTwister

@inline mt_avail(r::MersenneTwister) = MTCacheLength - r.idx
@inline mt_empty(r::MersenneTwister) = r.idx == MTCacheLength
@inline mt_setfull!(r::MersenneTwister) = r.idx = 0
@inline mt_setempty!(r::MersenneTwister) = r.idx = MTCacheLength
@inline mt_pop!(r::MersenneTwister) = @inbounds return r.vals[r.idx+=1]

function gen_rand(r::MersenneTwister)
    dsfmt_fill_array_close1_open2!(r.state, pointer(r.vals), length(r.vals))
    mt_setfull!(r)
end

@inline reserve_1(r::MersenneTwister) = (mt_empty(r) && gen_rand(r); nothing)
# `reserve` allows one to call `rand_inbounds` n times
# precondition: n <= MTCacheLength
@inline reserve(r::MersenneTwister, n::Int) = (mt_avail(r) < n && gen_rand(r); nothing)

# precondition: !mt_empty(r)
@inline rand_inbounds(r::MersenneTwister, ::Type{Close1Open2}) = mt_pop!(r)
@inline rand_inbounds(r::MersenneTwister, ::Type{CloseOpen}) = rand_inbounds(r, Close1Open2) - 1.0
@inline rand_inbounds(r::MersenneTwister) = rand_inbounds(r, CloseOpen)

# produce Float64 values
@inline rand(r::MersenneTwister, ::Type{I}) where {I<:FloatInterval} = (reserve_1(r); rand_inbounds(r, I))

@inline rand_ui52_raw_inbounds(r::MersenneTwister) = reinterpret(UInt64, rand_inbounds(r, Close1Open2))
@inline rand_ui52_raw(r::MersenneTwister) = (reserve_1(r); rand_ui52_raw_inbounds(r))
@inline rand_ui2x52_raw(r::MersenneTwister) = rand_ui52_raw(r) % UInt128 << 64 | rand_ui52_raw(r)

function srand(r::MersenneTwister, seed::Vector{UInt32})
    copy!(resize!(r.seed, length(seed)), seed)
    dsfmt_init_by_array(r.state, r.seed)
    mt_setempty!(r)
    return r
end

# MersenneTwister jump

"""
    randjump(r::MersenneTwister, jumps::Integer, [jumppoly::AbstractString=dSFMT.JPOLY1e21]) -> Vector{MersenneTwister}

Create an array of the size `jumps` of initialized `MersenneTwister` RNG objects. The
first RNG object given as a parameter and following `MersenneTwister` RNGs in the array are
initialized such that a state of the RNG object in the array would be moved forward (without
generating numbers) from a previous RNG object array element on a particular number of steps
encoded by the jump polynomial `jumppoly`.

Default jump polynomial moves forward `MersenneTwister` RNG state by `10^20` steps.
"""
function randjump(mt::MersenneTwister, jumps::Integer, jumppoly::AbstractString)
    mts = MersenneTwister[]
    push!(mts, mt)
    for i in 1:jumps-1
        cmt = mts[end]
        push!(mts, MersenneTwister(copy(cmt.seed), dSFMT.dsfmt_jump(cmt.state, jumppoly)))
    end
    return mts
end
randjump(r::MersenneTwister, jumps::Integer) = randjump(r, jumps, dSFMT.JPOLY1e21)

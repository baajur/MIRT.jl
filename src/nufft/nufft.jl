#=
nufft.jl
Non-uniform FFT (NUFFT), currently a wrapper around NFFT.jl
todo: open issues: small N, odd N, nufft!, adjoint!
2019-06-06, Jeff Fessler, University of Michigan
=#

export nufft_init, nufft_plots, nufft

#using MIRT: dtft_init, map_many
#include("../utility/map_many.jl")
using NFFT
using Plots
using LinearAlgebra: norm
using LinearMapsAA: LinearMapAA, LinearMapAM, LinearMapAO
using Test: @test, @testset, @test_throws


"""
    nufft_eltype(::DataType)
ensure NFFTPlan is Float32 or Float64
"""
nufft_eltype(::Type{<:Integer}) = Float32
nufft_eltype(::Type{<: Union{Float16,Float32}}) = Float32
nufft_eltype(::Type{Float64}) = Float64
nufft_eltype(T::DataType) = throw("unknown type $T")


# the following convenience routine ensures correct type passed to nfft()
# see https://github.com/tknopp/NFFT.jl/pull/33
# todo: may be unnecessary with future version of nfft()
"""
    nufft_typer(T::DataType, x::AbstractArray{<:Real} ; warn::Bool=true)
type conversion wrapper for `nfft()`
"""
nufft_typer(::Type{T}, x::T ; warn::Bool=true) where {T} = x # cf convert()

function nufft_typer(T::Type{TT}, x ; warn::Bool=true) where {TT}
    isinteractive() && @warn("converting $(eltype(x)) to $(eltype(T))")
    convert(T, x)
end


"""
    p = nufft_init(w, N ; nfft_m=4, nfft_sigma=2.0, pi_error=true, n_shift=0)

Setup 1D NUFFT,
for computing fast ``O(N \\log N)`` approximation to

``X[m] = sum_{n=0}^{N-1} x[n] exp(-i w[m] (n - n_shift)), m=1,…,M``

in
- `w::AbstractArray{<:Real}` `[M]` frequency locations (units radians/sample)
	+ `eltype(w)` determines the NFFTPlan type; so to save memory use Float32!
- `N::Int` signal length

option
- `nfft_m::Int` 		see NFFT.jl documentation; default 4
- `nfft_sigma::Real`	"", default 2.0
- `n_shift::Real`		often is N/2; default 0
- `pi_error::Bool`		throw error if ``|w| > π``, default `true`
   + Set to `false` only if you are very sure of what you are doing!
- `do_many::Bool`	support extended inputs via `map_many`? default `true`
- `operator::Bool=true` set to `false` to make `A` an `LinearMapAM`

out
- `p NamedTuple` with fields
	`nufft = x -> nufft(x), adjoint = y -> nufft_adj(y), A=LinearMapAO`

The default settings are such that for a 1D signal of length N=512,
the worst-case error is below 1e-5 which is probably adequate
for typical medical imaging applications.
To verify this statement, run `nufft_plot1()` and see plot.
"""
function nufft_init(w::AbstractArray{<:Real}, N::Int ;
	n_shift::Real = 0,
	nfft_m::Int = 4,
	nfft_sigma::Real = 2.0,
	pi_error::Bool = true,
	do_many::Bool = true,
	operator::Bool = true, # !
)

	N < 6 && throw("NFFT may be erroneous for small N")
	isodd(N) && throw("NFFT erroneous for odd N")
	pi_error && any(abs.(w) .> π) &&
		throw(ArgumentError("|w| > π is likely an error"))

	T = nufft_eltype(eltype(w))
	CT = Complex{T}
	CTa = AbstractArray{Complex{T}}
	f = convert(Array{T}, w/(2π)) # note: NFFTPlan must have correct type
	p = NFFTPlan(f, N, nfft_m, nfft_sigma) # create plan
	M = length(w)
	# extra phase here because NFFT always starts from -N/2
	phasor = convert(CTa, cis.(-w * (N/2 - n_shift)))
	phasor_conj = conj.(phasor)
	forw1 = x -> nfft(p, nufft_typer(CTa, x)) .* phasor
#	forw! = x,y -> nfft!(p, nufft_typer(CTa, x)) .* phasor # todo
	back1 = y -> nfft_adjoint(p, nufft_typer(CTa, y .* phasor_conj))

	A = LinearMapAA(forw1, back1, (M, N), # no "many" here!
		(name="nufft1", N=(N,), n_shift=n_shift, ) ; T=CT,
		operator = operator, # effectively "many" if true
	)

	if do_many
		forw = x -> map_many(forw1, x, (N,))
		back = y -> map_many(back1, y, (M,))
	else
		forw = forw1
		back = back1
	end

	return (nufft=forw, adjoint=back, A=A)
end


"""
    p = nufft_init(w, N ; nfft_m=4, nfft_sigma=2.0, pi_error=true, n_shift=?)

Setup multi-dimensional NUFFT,
for computing fast ``O(N \\log N)`` approximation to

``X[m] = sum_{n=0}^{N-1} x[n] exp(-i w[m,:] (n - n_shift)), m=1,…,M``

in
- `w::AbstractMatrix{<:Real}` `[M,D]` frequency locations (units radians/sample)
	+ `eltype(w)` determines the NFFTPlan type; so to save memory use Float32!
- `N::Dims` `[D]` signal dimensions

option
- `nfft_m::Int` 		see NFFT.jl documentation; default 4
- `nfft_sigma::Real`	"", default 2.0
- `n_shift::AbstractVector{<:Real}`	`[D]`	often is N/2; default zeros(D)
- `pi_error::Bool`		throw error if ``|w| > π``, default `true`
   + Set to `false` only if you are very sure of what you are doing!
- `do_many::Bool`	support extended inputs via `map_many`? default `true`
- `operator::Bool=true` set to `false` to make `A` an `LinearMapAM`

The default `do_many` option is designed for parallel MRI where the k-space
sampling pattern applies to every coil.
It may also be useful for dynamic MRI with repeated sampling patterns.
The coil and/or time dimensions must come after the spatial dimensions.

out
- `p NamedTuple` with fields
	`nufft = x -> nufft(x), adjoint = y -> nufft_adj(y), A=LinearMapAO`
	(Using `operator=true` allows the `LinearMapAO` to support `do_many`.)
"""
function nufft_init(w::AbstractMatrix{<:Real}, N::Dims ;
	n_shift::AbstractVector{<:Real} = zeros(Int, length(N)),
	nfft_m::Int = 4,
	nfft_sigma::Real = 2.0,
	pi_error::Bool = true,
	do_many::Bool = true,
	operator::Bool = true, # !
)

	any(N .< 6) && throw("NFFT may be erroneous for small N")
	any(isodd.(N)) && throw("NFFT erroneous for odd N")
	pi_error && any(abs.(w) .> π) &&
		throw(ArgumentError("|w| > π is likely an error"))

	M,D = size(w)
	length(N) != D && throw(DimensionMismatch("length(N) vs D=$D"))
	length(n_shift) != D && throw(DimensionMismatch("length(n_shift) vs D=$D"))

	T = nufft_eltype(eltype(w))
	CT = Complex{T}
	CTa = AbstractArray{Complex{T}}
	f = convert(Array{T}, w/(2π)) # note: NFFTPlan must have correct type
	p = NFFTPlan(f', N, nfft_m, nfft_sigma) # create plan

	# extra phase here because NFFT always starts from -N/2
	phasor = convert(CTa, cis.(-w * (collect(N)/2. - n_shift)))
	phasor_conj = conj.(phasor)
	forw1 = x -> nfft(p, nufft_typer(CTa, x)) .* phasor
	back1 = y -> nfft_adjoint(p, nufft_typer(CTa, y .* phasor_conj))

	if operator # LinearMapAO
		A = LinearMapAA(forw1, back1, (M, prod(N)),
			(name="nufft$(length(N))", N=N, n_shift=n_shift) ; T=CT,
			operator = true,
			idim = N,
		)
	else
		# no "many" for LinearMapAM:
		A = LinearMapAA(x -> forw1(reshape(x,N)), y -> vec(back1(y)), (M, prod(N)),
			(name="nufft$(length(N))", N=N, n_shift=n_shift) ; T=CT,
		)
	end

	if do_many
		forw = x -> map_many(forw1, x, N)
		back = y -> map_many(back1, y, (M,))
	else
		forw = forw1
		back = back1
	end

	return (nufft=forw, adjoint=back, A=A)
end



"""
nufft_test1( ; M=30, N=20, n_shift=1.7, T=?, tol=?)
simple 1D tests
"""
function nufft_test1( ;
	M::Int = 30, N::Int = 20, n_shift::Real = 1.7,
	T::DataType = Float64, tol::Real = 2e-6,
)

	w = (rand(M) .- 0.5) * 2 * pi
	w = T.(w)
	x = randn(complex(T), N)
	sd = dtft_init(w, N ; n_shift=n_shift)
	sn = nufft_init(w, N ; n_shift=n_shift, operator=false)
	o0 = sd.dtft(x)
	y = Complex{T}.(o0 / norm(o0))
	a0 = sd.adjoint(y)
	o1 = sn.nufft(x)
	o2 = sn.A * x
	a1 = sn.adjoint(y)
	a2 = sn.A' * y
	@test norm(o1 - o0, Inf) / norm(o0, Inf) < tol
	@test isequal(o1, o2)
	@test norm(a1 - a0, Inf) / norm(a0, Inf) < tol
	@test isequal(a1, a2)
	@test Matrix(sn.A)' ≈ Matrix(sn.A') # 1D adjoint test

	A = sn.A
	@test A.name == "nufft1"
	@test A isa LinearMapAM

	sn = nufft_init(w, N, n_shift=n_shift, do_many=false, operator=true)
	o3 = sn.nufft(x)
	@test norm(o3 - o0, Inf) / norm(o0, Inf) < tol

	B = sn.A
	@test B isa LinearMapAO

	sn.nufft(ones(Int,N)) # produce a "conversion" warning
	true
end


"""
nufft_test2( ; M=?, N=?, n_shift=?, T=?, tol=?)
simple 2D test
"""
function nufft_test2( ;
	M::Int = 31,
	N::Dims = (10,8),
	n_shift::AbstractVector{<:Real} = [4,3],
	T::DataType = Float64, tol::Real = 2e-6,
)

	w = []

#=
	# fft sampling
	M = prod(N)
	w1 = (2*pi) * (0:N[1]-1) / N[1]
    w2 = (2*pi) * (0:N[2]-1) / N[2]
    w1 = repeat(w1, 1, N[2])
    w2 = repeat(w2', N[1], 1)
    w = [vec(w1) vec(w2)]
	n_shift = [0,0]
=#

	w = (rand(M,2) .- 0.5) * 2 * pi

	w = T.(w)
	sd = dtft_init(w, N ; n_shift=n_shift)
	sn = nufft_init(w, N ; n_shift=n_shift, pi_error=false)

	x = randn(Complex{T}, N)
	o0 = sd.dtft(x)
	o1 = sn.nufft(x)
	@test norm(o1 - o0, Inf) / norm(o0, Inf) < tol

#=
	# fft test only
	o2 = fft(x)
	o0 = reshape(o0, N)
	o1 = reshape(o1, N)
	@show norm(o2 - o0, Inf) / norm(o0, Inf)
	@show norm(o1 - o0, Inf) / norm(o0, Inf)
	@show norm(o2 - o1, Inf) / norm(o0, Inf)
=#

	y = convert(Array{Complex{T}}, o0 / norm(o0))
	a0 = sd.adjoint(y)
	a1 = sn.adjoint(y)
	@test norm(a1 - a0, Inf) / norm(a0, Inf) < tol
	o2 = sn.A * x
	@test isequal(o1, o2)
	a2 = sn.A' * y
	@test isequal(a1, a2)
	@test Matrix(sn.A)' ≈ Matrix(sn.A') # 2D adjoint test

	@test isequal(sn.nufft(cat(dims=4, x, 2x)),
		cat(dims=3, sn.nufft(x), sn.nufft(2x)))
	@test isequal(sn.adjoint(cat(dims=3, y, 2y)),
			cat(dims=4, sn.adjoint(y), sn.adjoint(2y)))

	A = sn.A
	@test A.name == "nufft2"
	@test A.N == N

	Ao = nufft_init(w, N ; n_shift=n_shift, pi_error=false, operator=true).A
	Am = nufft_init(w, N ; n_shift=n_shift, pi_error=false, operator=false).A
	@test Ao * x == Am * vec(x)
	y = Ao * x
	@test Ao'*y == reshape(Am'*y, N)

	sn = nufft_init(w, N ; n_shift=n_shift, pi_error=false,
		do_many=false, operator=true)
	o3 = sn.nufft(x)
	@test norm(o3 - o0, Inf) / norm(o0, Inf) < tol
	true
end


"""
w, errs = nufft_errors( ; M=?, w=?, N=?, n_shift=?, ...)

Compute worst-case errors for NUFFT (for signal of length N of unit norm)
"""
function nufft_errors( ;
	M::Int = 401,
	N::Int = 512,
	w::AbstractArray{<:Real} = LinRange(0, 2π/N, M),
	n_shift::Real = 0,
	kwargs...,
)

	sd = dtft_init(w, N ; n_shift=n_shift)
	sn = nufft_init(w, N ; n_shift=n_shift, kwargs...)
	E = Matrix(sn.A - sd.A)
	return w, vec(mapslices(norm, E, dims=2)) # [M]
end


"""
nufft_plot1()

Plot worst-case error over all frequencies w between 0 and 2pi/N for various N.
"""
function nufft_plot1()
	Nlist = 2 .^ (4:9)
	elist = zeros(length(Nlist))
	for (ii, N) in enumerate(Nlist)
		w, errs = nufft_errors( ; N = N)
	#	plot(w*N/2/π, tmp)
		elist[ii] = maximum(errs)
	end
	scatter(Nlist, elist, xtick=Nlist, label="", xlabel="N", ylabel="error")
end


"""
nufft_plot_error_m( ; mlist=?)

Plot error vs NFFT sigma
"""
function nufft_plot_error_m(;
	mlist::AbstractArray{<:Int} = 3:7)
	worst = zeros(length(mlist))
	for (jm,nfft_m) = enumerate(mlist)
		_, errs = nufft_errors( ; nfft_m=nfft_m)
		worst[jm] = maximum(errs)
	end
	scatter(mlist, worst, xlabel="m", ylabel="error", label="")
end


"""
nufft_plot_error_s( ; slist=?)

Plot error vs NFFT sigma
"""
function nufft_plot_error_s( ;
	slist::AbstractArray{<:Real} = [1.5; 2:6])
	worst = zeros(length(slist))
	for (is,σ) in enumerate(slist)
		_, errs = nufft_errors(; nfft_sigma=σ)
		worst[is] = maximum(errs)
	end
	scatter(slist, worst, xlabel="σ", ylabel="error", label="")
end


"""
    nufft_plots()
various NUFFT error plots
"""
function nufft_plots()
	p1 = nufft_plot_error_s()
	p2 = nufft_plot_error_m()
	p3 = nufft_plot1()
	plot(p1, p2, p3)
end


"""
    nufft(:test)
self tests
"""
function nufft(test::Symbol)
	test != :test && throw("bad symbol $test")
	@testset "basics" begin
		@test nufft_eltype(Bool) === Float32
		@test nufft_eltype(Float16) === Float32
		@test nufft_eltype(Float64) === Float64
		@test_throws String nufft_eltype(BigFloat)
		@test_throws String nufft_init([0], 2) # small
		@test_throws String nufft_init([0], 7) # odd
		@test_throws ArgumentError nufft_init([2π], 8) # π
	end
	@testset "1D" begin
		@test nufft_test1()
		@test nufft_test1(; T=Float32)
	end
	@testset "2D" begin
		@test nufft_test2()
		@test nufft_test2(; T=Float32)
	end
	@testset "plots" begin
		@test nufft_plots() isa Plots.Plot
	end
	true
end


#=
	# todo: 1d vs 2d
	M = 4
	N = (M,1)
	w = (0:(M-1))/M * 2 * pi
	w = [w zeros(M)]
	sd = dtft_init(w, N)
	Ad = Matrix(sd.A)
	sn1 = nufft_init(w[:,1], N[1]; pi_error=false)
	An1 = Matrix(sn1.A)
	@show maximum(abs.(An1 - Ad))
	sn2 = nufft_init(w, N; pi_error=false)
	An2 = Matrix(sn2.A)
#	@show o0 = sd.dtft(x)
#	@show o1 = sn.nufft(x)
#	@show o1-o0
#	@test maximum(abs.(o1 - o0)) < tol
=#


#=
	# todo MWE for 1D vs 2D
	M = 6
	x1 = collect((-Int(M/2)):(Int(M/2)-1))/M
	N1 = M
	p1 = NFFTPlan(x1, N1)
#	p1 = NFFTPlan(x1', (N1,)) # this works too
#	f1 = ones(N1)
	f1 = [1.,2,3,4,0,0]
	o1 = nfft(p1, complex(f1)) # slightly annoying to have to use complex() here

	N2 = (M,4) # works fine with "4" instead of "1" here and separable signal
	x2 = [x1 zeros(M)]
	p2 = NFFTPlan(x2', N2)
	f2 = f1 * [0,0,1,0]'
	o2 = nfft(p2, complex(f2)) # ditto

	display(round.(o1, digits=7))
	display(round.(o2, digits=7))

#	tmp = nufft_init(x1*2*pi, N1)
=#


#nufft(:test)
#nufft_test1(;N=41) # todo: inaccurate

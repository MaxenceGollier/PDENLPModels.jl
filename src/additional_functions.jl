#ℓ(x) = obj_weight * nlp.f(x)
#Hv .= ForwardDiff.derivative(t -> ForwardDiff.gradient(ℓ, x + t * v), 0)
"""
Compute hessian-vector product of the objective function.

Note: this is not efficient at all.
Test on n=14115
@btime hprod(nlp, sol_gridap, v)
  42.683 s (274375613 allocations: 29.89 GiB)
while computing the hessian and then the product yields
@btime _Hx = hess(nlp, sol_gridap);
  766.036 ms (724829 allocations: 121.84 MiB)
@btime hprod(nlp, sol_gridap, v)
  42.683 s (274375613 allocations: 29.89 GiB)

"""
function hprod_autodiff!(nlp :: GridapPDENLPModel, x :: AbstractVector, v :: AbstractVector, Hv :: AbstractVector; obj_weight :: Real = one(eltype(x)))
  @lencheck nlp.meta.nvar x v Hv
  increment!(nlp, :neval_hprod)

  if obj_weight == zero(eltype(x))
      Hv .= zero(similar(x))
      return Hv
  end

  assem = Gridap.FESpaces.SparseMatrixAssembler(nlp.Y, nlp.X)
  #We prepare computation of x + t * v
  #At t=0.
  yu    = FEFunction(nlp.Y, x)
  vf    = FEFunction(nlp.Y, v)

  cell_yu   = Gridap.FESpaces.get_cell_values(yu)
  cell_vf   = Gridap.FESpaces.get_cell_values(vf)
  ncells    = length(cell_yu)
  cell_id   = Gridap.Arrays.IdentityVector(ncells)

  function _cell_obj_t(cell)
       th = CellField(nlp.Y, cell)
      _th = Gridap.FESpaces.restrict(th, nlp.trian)
      integrate(nlp.f(_th), nlp.trian, nlp.quad) #function needs to return array of size 1.
  end

  #Compute the gradient with AD
  function _cell_grad_t(t)
      ct     = t * ones(length(cell_vf[1]))
      _cell  = Array{typeof(ct .* cell_vf[1])}(undef, ncells)
      for i=1:ncells
          _cell[i] = cell_yu[i] + ct .* cell_vf[i]
      end
      Gridap.Arrays.autodiff_array_gradient(_cell_obj_t, _cell, cell_id)
  end

  #Compute the derivative w.r.t. to t of _cell_grad_t
  #This might be slow as it cannot be decomposed (easily) cell by cell
  cell_r_yu = ForwardDiff.derivative(_cell_grad_t, 0.)

  #Put the result in the format expected by Gridap.FESpaces.assemble_matrix
  vecdata_yu = [[cell_r_yu], [cell_id]]
  #Assemble the gradient in the "good" space
  Hv .= Gridap.FESpaces.assemble_vector(assem, vecdata_yu)

  return Hv
end

function hess(nlp :: GridapPDENLPModel, x :: AbstractVector; obj_weight :: Real = one(eltype(x)))

    assem = Gridap.FESpaces.SparseMatrixAssembler(nlp.Y, nlp.X)
    yu    = FEFunction(nlp.Y, x)

    cell_yu    = Gridap.FESpaces.get_cell_values(yu)
    cell_id_yu = Gridap.Arrays.IdentityVector(length(cell_yu))

    #
    function _cell_obj_yu(cell_yu)
         yuh = CellField(nlp.Y, cell_yu)
        _yuh = Gridap.FESpaces.restrict(yuh, nlp.trian)
        integrate(nlp.f(_yuh), nlp.trian, nlp.quad)
    end

    #Compute the hessian with AD
    cell_r_yu  = Gridap.Arrays.autodiff_array_hessian(_cell_obj_yu, cell_yu, cell_id_yu)
    #Put the result in the format expected by Gridap.FESpaces.assemble_matrix
    matdata_yu = [[cell_r_yu], [cell_id_yu], [cell_id_yu]]
    #Assemble the matrix in the "good" space
    hess_yu   = Gridap.FESpaces.assemble_matrix(assem, matdata_yu)

    #Tangi: test symmetry (should be removed later on)
    if !issymmetric(hess_yu) throw("Error: non-symmetric hessian matrix") end

    #https://github.com/JuliaLang/julia/blob/539f3ce943f59dec8aff3f2238b083f1b27f41e5/base/iterators.jl#L110-L132

    return sparse(LowerTriangular(hess_yu)) #there must be a better way for this
end

"""
`_get_y_and_u(:: GridapPDENLPModel, :: AbstractVector{T}) `

Returns y and u in matrix format where
y ∈ n_edp_fields x nvar_per_field
u ∈ n_control_fields x nvar_per_field
It is useful when evaluating the function constraint (and jacobian) functions.
"""
function _get_y_and_u(nlp :: GridapPDENLPModel, x :: AbstractVector{T}) where T

    y = Array{T,2}(undef, nlp.n_edp_fields, nlp.nvar_per_field)
    for i=1:nlp.n_edp_fields
        y[i,:] = [x[k] for k in i:nlp.n_edp_fields:nlp.nvar_edp]
    end

    u = Array{T,2}(undef, nlp.n_control_fields, nlp.nvar_per_field)
    for i=1:nlp.n_control_fields
        u[i,:] = [x[k] for k in nlp.nvar_edp+i:nlp.n_control_fields:nlp.meta.nvar-nlp.nparam]
    end

    return y, u
end

function _get_y_and_u_i(nlp :: GridapPDENLPModel, x :: AbstractVector{T}, j :: Int) where T

    y = Array{T,1}(undef, nlp.n_edp_fields)
    for i=1:nlp.n_edp_fields
        y[i] = x[(j-1)*nlp.n_edp_fields + i]
    end

    u = Array{T,1}(undef, nlp.n_control_fields)
    for i=1:nlp.n_control_fields
        u[i] = x[nlp.nvar_edp+(j-1)*nlp.n_control_fields + i]
    end

    return y, u
end

function _get_y_and_u_i(nlp :: GridapPDENLPModel, x :: AbstractVector{T}, v :: AbstractVector{T}, j :: Int) where T

    _v = Array{T,1}(undef, nlp.n_edp_fields + nlp.n_control_fields)

    y = Array{T,1}(undef, nlp.n_edp_fields)
    for i=1:nlp.n_edp_fields
        y[i] = x[(j-1)*nlp.n_edp_fields + i]
       _v[i] = v[(j-1)*nlp.n_edp_fields + i]
    end

    u = Array{T,1}(undef, nlp.n_control_fields)
    for i=1:nlp.n_control_fields
        u[i] = x[nlp.nvar_edp + (j-1) * nlp.n_control_fields + i]
       _v[i] = v[nlp.n_edp_fields + nlp.nvar_edp + (j-1) * nlp.n_control_fields + i]
    end

    return y, u, _v
end

"""
Would be better but somehow autodiff_cell_jacobian_from_residual is restricted to square matrices at some point.
"""
function _from_terms_to_jacobian2(op  :: Gridap.FESpaces.FEOperatorFromTerms,
                                  x   :: AbstractVector{T},
                                  nlp :: GridapPDENLPModel) where T <: AbstractFloat

    #Notations
    nvar_edp         = nlp.nvar_edp
    nvar_control     = nlp.nvar_control
    nvar_per_field   = nlp.nvar_per_field
    n_control_fields = nlp.n_control_fields
    n_edp_fields     = nlp.n_edp_fields
    nfields          = nlp.meta_func.nvar
    nconf            = nlp.meta_func.ncon

    A = Array{T,2}(undef, nvar_edp, nvar_edp + nvar_control)
    yu = FEFunction(nlp.Y, x)
    du = Gridap.FESpaces.get_cell_basis(nlp.Y) #use only jac is furnished
    v  = Gridap.FESpaces.get_cell_basis(nlp.Xedp)

    w,r,c = [], [], []
    for term in nlp.op.terms

      _v  = restrict(v,  term.trian)

      cellids  = Gridap.FESpaces.get_cell_id(term)

      function yuh_to_cell_residual(yuf)
        _yuf = Gridap.FESpaces.restrict(yuf, term.trian)
        integrate(term.res(_yuf,_v), term.trian, term.quad)
      end

      cellvals_y = Gridap.FESpaces.autodiff_cell_jacobian_from_residual(yuh_to_cell_residual, yu, cellids) ###Problem here!
      #end
      Gridap.FESpaces._push_matrix_contribution!(w,r,c,cellvals_y,cellids)

    end

    assem_y = Gridap.FESpaces.SparseMatrixAssembler(nlp.Y, nlp.Xedp)
    Gridap.FESpaces.assemble_matrix!(A, assem_y, (w,r,c))
    return A
end

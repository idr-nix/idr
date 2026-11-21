{-# OPTIONS --safe --erasure #-}

module IDR.Mesh.Retention where

open import Agda.Builtin.Bool using (Bool; true; false)
open import Agda.Builtin.Equality using (_≡_; refl)
open import Agda.Builtin.List using (List; []; _∷_)

infix 4 _∈_
data @0 _∈_ {A : Set} (p : A) : List A → Set where
  here  : ∀ {ps} → p ∈ (p ∷ ps)
  there : ∀ {q ps} → p ∈ ps → p ∈ (q ∷ ps)

private
  infixr 6 _∧_
  _∧_ : Bool → Bool → Bool
  true  ∧ b = b
  false ∧ _ = false

  collect : ∀ {A : Set} → (A → Bool) → (A → A) → List A → List A → List A
  collect select project []       rest = rest
  collect select project (p ∷ ps) rest with select p
  ... | true  = project p ∷ collect select project ps rest
  ... | false = collect select project ps rest

  @0 keeps-selected :
    ∀ {A : Set} (select : A → Bool) (project : A → A) {p ps} →
    p ∈ ps → select p ≡ true → project p ∈ collect select project ps []
  keeps-selected select project here yes rewrite yes = here
  keeps-selected select project (there {q} member) yes with select q
  ... | true  = there (keeps-selected select project member yes)
  ... | false = keeps-selected select project member yes

  @0 keeps-rest :
    ∀ {A : Set} (select : A → Bool) (project : A → A) (ps : List A) {p rest} →
    p ∈ rest → p ∈ collect select project ps rest
  keeps-rest select project []       member = member
  keeps-rest select project (q ∷ qs) member with select q
  ... | true  = there (keeps-rest select project qs member)
  ... | false = keeps-rest select project qs member

  @0 _++_ : ∀ {A : Set} → List A → List A → List A
  []       ++ ys = ys
  (x ∷ xs) ++ ys = x ∷ (xs ++ ys)

  @0 cong : ∀ {A B : Set} (f : A → B) {x y} → x ≡ y → f x ≡ f y
  cong f refl = refl

module _ {Peer : Set} (admissible declared keyFree addressFree : Peer → Bool)
         (markAbsent : Peer → Peer) where

  keep : Peer → Bool
  keep p = declared p ∧ admissible p ∧ keyFree p ∧ addressFree p

  -- Key and address availability refer to all fresh registrations.
  reconcile : List Peer → List Peer → List Peer
  reconcile fresh cache = collect admissible (λ p → p) fresh (collect keep markAbsent cache [])

  @0 lease-loss-retains :
    ∀ fresh cache {p} → p ∈ cache →
    admissible p ≡ true → declared p ≡ true → keyFree p ≡ true → addressFree p ≡ true →
    markAbsent p ∈ reconcile fresh cache
  lease-loss-retains fresh cache {p} member admissible-p declared-p free-key free-address =
    keeps-rest admissible (λ q → q) fresh (keeps-selected keep markAbsent member eligible)
    where
      eligible : keep p ≡ true
      eligible rewrite declared-p | admissible-p | free-key | free-address = refl

  -- A withdrawn declaration removes its cached entry wherever it occurs,
  -- preserving the rest of the result, including the order of other peers.
  @0 revocation-withdraws :
    ∀ fresh before p after → declared p ≡ false →
    reconcile fresh (before ++ (p ∷ after)) ≡ reconcile fresh (before ++ after)
  revocation-withdraws fresh before p after revoked =
    cong (collect admissible (λ q → q) fresh) (skip before)
    where
      skip : ∀ prefix → collect keep markAbsent (prefix ++ (p ∷ after)) []
                      ≡ collect keep markAbsent (prefix ++ after) []
      skip [] rewrite revoked = refl
      skip (q ∷ qs) with keep q
      ... | true  = cong (markAbsent q ∷_) (skip qs)
      ... | false = skip qs

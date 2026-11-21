{-# OPTIONS --safe --erasure #-}

-- Both ends of a connection pick its PSK from the same two adverts. The choice
-- must not depend on which end computes it, and must be a key both ends hold.
module IDR.Mesh.Agreement where

open import Agda.Builtin.Bool using (Bool; true; false)
open import Agda.Builtin.Equality using (_≡_; refl)
open import Agda.Builtin.List using (List; []; _∷_)
open import Agda.Builtin.Maybe using (Maybe; just; nothing)

-- The key an end wants and every key it can install, including the wanted one.
record Advert (H : Set) : Set where
  constructor advert
  field
    wanted : H
    usable : List H

open Advert

_&&_ : Bool → Bool → Bool
true && b = b
false && _ = false

module _ {K H : Set} (before : K → K → Bool) (same : H → H → Bool) where

  member : H → List H → Bool
  member h [] = false
  member h (x ∷ xs) = choice (same h x)
    where
      choice : Bool → Bool
      choice true = true
      choice false = member h xs

  shared : Advert H → Advert H → H → Bool
  shared a b h = member h (usable a) && member h (usable b)

  select : Bool → H → Maybe H → Maybe H
  select true x _ = just x
  select false _ rest = rest

  first : (H → Bool) → List H → Maybe H
  first p [] = nothing
  first p (x ∷ xs) = select (p x) x (first p xs)

  -- Prefer the wanted key of the end with the lower public key, then the other
  -- end's, then any key both ends hold.
  choose : Advert H → Advert H → Maybe H
  choose lo hi = first (shared lo hi) (wanted lo ∷ wanted hi ∷ usable lo)

  pick : Bool → Advert H → Advert H → Maybe H
  pick true x y = choose x y
  pick false x y = choose y x

  agreed : K → Advert H → K → Advert H → Maybe H
  agreed kx x ky y = pick (before kx ky) x y

  -- Symmetry: for two distinct keys exactly one comes first, so both ends
  -- compute the same result.
  pick-swap : ∀ b c x y → (b ≡ true → c ≡ false) → (b ≡ false → c ≡ true) → pick b x y ≡ pick c y x
  pick-swap true c x y opposite _ rewrite opposite refl = refl
  pick-swap false c x y _ opposite rewrite opposite refl = refl

  symmetric :
    ∀ kx x ky y →
    (before kx ky ≡ true → before ky kx ≡ false) →
    (before kx ky ≡ false → before ky kx ≡ true) →
    agreed kx x ky y ≡ agreed ky y kx x
  symmetric kx x ky y = pick-swap (before kx ky) (before ky kx) x y

  -- Usability: an agreed key is one both ends can install.
  first-sound : ∀ p hs h → first p hs ≡ just h → p h ≡ true
  first-sound p [] h ()
  first-sound p (x ∷ xs) h found = step (p x) refl found
    where
      step : (b : Bool) → p x ≡ b → select b x (first p xs) ≡ just h → p h ≡ true
      step true holds refl = holds
      step false _ later = first-sound p xs h later

  left : ∀ a b → (a && b) ≡ true → a ≡ true
  left true _ _ = refl
  left false _ ()

  right : ∀ a b → (a && b) ≡ true → b ≡ true
  right true _ holds = holds
  right false _ ()

  record Held (x y : Advert H) (h : H) : Set where
    field
      byFirst : member h (usable x) ≡ true
      bySecond : member h (usable y) ≡ true

  held : ∀ kx x ky y h → agreed kx x ky y ≡ just h → Held x y h
  held kx x ky y h = step (before kx ky)
    where
      step : (b : Bool) → pick b x y ≡ just h → Held x y h
      step true found =
        let both = first-sound (shared x y) (wanted x ∷ wanted y ∷ usable x) h found
         in record {byFirst = left _ _ both; bySecond = right _ _ both}
      step false found =
        let both = first-sound (shared y x) (wanted y ∷ wanted x ∷ usable y) h found
         in record {byFirst = right _ _ both; bySecond = left _ _ both}

{-# OPTIONS --erasure #-}

module IDR.Mesh.Foreign where

open import Agda.Builtin.Bool using (Bool)
open import Agda.Builtin.List using (List)
open import Agda.Builtin.Maybe using (Maybe)
import IDR.Mesh.Agreement as Agreement
import IDR.Mesh.Retention as Retention

-- Give the checked functions stable Haskell names.
reconcile : {Peer : Set} → (Peer → Bool) → (Peer → Bool) → (Peer → Bool) → (Peer → Bool) →
            (Peer → Peer) → List Peer → List Peer → List Peer
reconcile = Retention.reconcile
{-# COMPILE GHC reconcile as reconcile #-}

-- Each end is its public key, wanted key and usable keys in ascending order.
agreed : {K H : Set} → (K → K → Bool) → (H → H → Bool) → K → H → List H → K → H → List H → Maybe H
agreed before same kx wx ux ky wy uy = Agreement.agreed before same kx (Agreement.advert wx ux) ky (Agreement.advert wy uy)
{-# COMPILE GHC agreed as agreed #-}

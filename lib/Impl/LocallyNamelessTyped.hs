{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE QuantifiedConstraints #-}
{-# LANGUAGE TypeOperators #-}

-- | Based directly on transliteration of Coq output for Ott Locally Nameless Backend
-- Then with types addded
module Impl.LocallyNamelessTyped where

import qualified Control.Monad.State as State
import qualified Data.IntMap as IM
import Data.List (elemIndex)
import qualified Data.Set as Set
import Data.Type.Equality
import IdInt
import Impl
import Imports hiding (S, lift)
import qualified Lambda as LC
import qualified Unsafe.Coerce as Unsafe

-- 0. Original
-- lennart: 1.03s
-- random: 0.807 ms

-- 1. Well-typed (slows it down)
-- lennart: 1.43s
-- random: 1.8ms
-------------------------------------------------------------------

-- Index to keep track of bound variable scope
data Nat = Z | S Nat

data SNat n where
  SZ :: SNat Z
  SS :: SNat n -> SNat (S n)

type family Plus n m where
  Plus Z n = n
  Plus (S m) n = S (Plus m n)

instance Show (SNat m) where
  show SZ = "SZ"
  show (SS n) = "(SS " ++ show n ++ ")"

------------------------------------

-- Bound variable index
-- Natural number is # of potential variables in scope
-- Idx Z is a Void type.
-- Idx (S Z) has a single inhabitant: FZ
data Idx :: Nat -> Type where
  FZ :: Idx (S n)
  FS :: Idx n -> Idx (S n)

instance Eq (Idx n) where
  FZ == FZ = True
  (FS n) == (FS m) = n == m
  _ == _ = False

instance Show (Idx n) where
  show FZ = "FZ"
  show (FS n) = "(FS " ++ show n ++ ")"

toInt :: Idx n -> Int
toInt FZ = 0
toInt (FS n) = 1 + toInt n

shift :: SNat m -> Idx n -> Idx (Plus m n)
shift SZ x = x
shift (SS m) x = FS (shift m x)

--------------------------------------------------------------

instance (forall n. NFData (a n)) => NFData (Bind a m) where
  rnf (Bind s a) =
    -- rnf s `seq`
    rnf a

instance NFData (Idx a) where
  rnf FZ = ()
  rnf (FS s) = rnf s

instance NFData (SNat a) where
  rnf SZ = ()
  rnf (SS s) = rnf s

--------------------------------------------------------------
--------------------------------------------------------------

-- Locally nameless simplification.
-- We only use substBv to implement open
-- when we open, we only replace with locally closed terms
-- and we only use open for variables with a single bound variable.
-- This means that we do *not* need to shift as much.

data Bind a k where
  --Bind :: Sub n (S k) -> !(a (Plus n (S k))) -> Bind a k
  Bind :: b -> !(a (S k)) -> Bind a k

-- create a binding by "abstracting a variable"
bind :: SNat k -> a (S k) -> Bind a k
bind k x = Bind (Sub (SS k) VNil) x
{-# INLINEABLE bind #-}

unbind :: forall k. Bind Exp k -> Exp (S k)
unbind (Bind _ss a) = a -- multi_open_exp_wrt_exp_rec ss a
{-# INLINEABLE unbind #-}

instance (Eq (Exp (S n))) => Eq (Bind Exp n) where
  b1 == b2 = unbind b1 == unbind b2

-- Exp Z is  locally closed terms
data Exp (n :: Nat) where
  Var_b :: !(Idx n) -> Exp n
  Var_f :: !IdInt -> Exp n
  Abs :: !(Bind Exp n) -> Exp n
  App :: !(Exp n) -> !(Exp n) -> Exp n
  deriving (Generic)

-- instance Show (Exp n) where

-- keep track of the opening that has been done already
-- via bound-variable substitution
-- a substitution looks like
-- k=1    0 -> 0 , 1 -> 1 , k+1 -> x, k+2 -> y, ...
-- as we apply it underneath a binding, it needs to be converted to
-- a larger scope (where the newly bound variables are left alone).
-- k=2    0 -> 0 , 1 -> 1 , 2 -> 2, k+1 -> x, k+2 -> y, ...
-- more generally, we have the scope depth k and a n-ary mapping for variables k+i for 0<=i<n
data Vec (n :: Nat) where
  VNil :: Vec Z
  VCons :: Exp Z -> Vec n -> Vec (S n)

nth :: SNat n -> Vec (S n) -> Exp Z
nth SZ (VCons a _) = a
nth (SS m) (VCons _ ss) = nth m ss

inth :: Idx n -> Vec n -> Exp Z
inth FZ (VCons a _) = a
inth (FS m) (VCons _ ss) = inth m ss

append :: Vec m -> Vec n -> Vec (Plus m n)
append VNil v = v
append (VCons u vm) vn = VCons u (append vm vn)

data Sub n k where
  Sub :: SNat k -> Vec n -> Sub n k

emptySub :: Sub Z Z
emptySub = Sub SZ VNil

appendSub :: Sub m k -> Sub n k -> Sub (Plus m n) k
appendSub (Sub k ss0) (Sub _ ss1) = Sub k (append ss0 ss1)

lift :: Sub n k -> Sub n (S k)
lift (Sub n ss) = Sub (SS n) ss

plus_comm :: forall n k. S (Plus n k) :~: Plus n (S k)
plus_comm = Unsafe.unsafeCoerce Refl

plus_Z_r :: forall n. Plus n Z :~: n
plus_Z_r = Unsafe.unsafeCoerce Refl

plus_inj :: forall n k m. Plus n (S k) :~: S m -> Plus n k :~: m
plus_inj = Unsafe.unsafeCoerce Refl

multi_open_exp_wrt_exp_rec :: forall n k. Sub n k -> Exp (Plus n k) -> Exp k
multi_open_exp_wrt_exp_rec ss@(Sub k v) e =
  case e of
    Var_b (i :: Idx (Plus n k)) -> openIdx i k v
    Var_f x -> Var_f x
    Abs (Bind ss1 b) --  -> Abs (Bind (ss1 `appendSub` ss0) b)
      | Refl <- plus_comm @n @k ->
        Abs (Bind k (multi_open_exp_wrt_exp_rec (Sub (SS k) v) b))
    (App e1 e2) ->
      App
        (multi_open_exp_wrt_exp_rec ss e1)
        (multi_open_exp_wrt_exp_rec ss e2)

shiftV :: Exp k -> Exp (S k)
shiftV (Var_b n) = Var_b (FS n)
shiftV x = Unsafe.unsafeCoerce x

-- when we find a bound variable, determine whether we should
-- leave it alone or replace it
openIdx :: forall n k. Idx (Plus n k) -> SNat k -> Vec n -> Exp k
openIdx i SZ v
  | Refl <- plus_Z_r @n = inth i v
openIdx FZ (SS n) v = Var_b FZ
openIdx (FS (m :: Idx m0)) (SS (k :: SNat k0)) v
  | Refl <- plus_comm @n @k0 =
    shiftV (openIdx m k v)
  where
    p1 :: S m0 :~: Plus n (S k0)
    p1 = Refl
    p2 :: S k0 :~: k
    p2 = Refl
    p3 :: S (Plus n k0) :~: Plus n (S k0)
    p3 = plus_comm @n @k0
    p5 :: m0 :~: Plus n k0
    p5 = Unsafe.unsafeCoerce Refl

{-
openIdx _ SZ (SCons =
openIdx (FS n) (SCons _u ss) = weaken <$> lookupIdx n ss
openIdx (FS n) SNil = Nothing
openIdx (FZ (SCons u _) =
-}
--open_bind_wrt_bind :: SNat n -> Exp Z -> Bind Exp (S n) -> Bind Exp n
--open_bind_wrt_bind k1 u (Bind (Sub k1 e) = Bind (open_exp_wrt_exp_rec (SS k) u e)

-- either n is equal to m or greater than m
compareIdx :: SNat k -> Idx (S k) -> Maybe (Idx k)
compareIdx SZ FZ = Nothing
compareIdx (SS m) (FS n) = FS <$> compareIdx m n
compareIdx SZ (FS m) = Nothing
compareIdx (SS _) FZ = Just FZ

{-
open_exp_wrt_exp_rec :: forall n. SNat n -> Exp Z -> Exp (S n) -> Exp n
open_exp_wrt_exp_rec k u e =
  case e of
    (Var_b (n :: Idx (S n))) ->
      case compareIdx k n of
        Just i -> Var_b i
        Nothing -> weaken u
    (Var_f x) -> Var_f x
    (Abs b) -> Abs (open_bind_wrt_bind k u b)
    (App e1 e2) ->
      App
        (open_exp_wrt_exp_rec k u e1)
        (open_exp_wrt_exp_rec k u e2)
-}

open :: Bind Exp Z -> Exp Z -> Exp Z
open (Bind _ss e) u = f
  where
    f = multi_open_exp_wrt_exp_rec (Sub SZ (VCons u VNil)) e

-- if n2 is greater than n1 increment it. Otherwise just return it.
cmpIdx :: Idx (S n) -> Idx n -> Idx (S n)
cmpIdx n1 n2 =
  case (n1, n2) of
    (FS m, FZ) -> FZ
    (FS m, FS n) -> FS (cmpIdx m n)
    (FZ, FZ) -> FZ
    (FZ, FS n) -> FS FZ

-- Create a new "bound index" from a free variable
-- The index starts at FZ and comes from a larger scope
-- All variables that are less than the new index must be incremented.

{-
close_subst_wrt_exp :: Idx (S n) -> IdInt -> Sub Exp m n -> Maybe (Sub Exp m (S n))
close_subst_wrt_exp FZ x1 (Cons (Var_f x2) (Inc SZ))
  | x1 == x2 = Just $ Inc SZ
close_subst_wrt_exp (FS m) x1 (Cons u ss) =
  do
    ss' <- close_subst_wrt_exp m x1 ss
    return $ Cons (close_exp_wrt_exp_rec (FS m) x1 u) ss'
-}

close_exp_wrt_exp_rec :: SNat n -> Idx (S n) -> IdInt -> Exp n -> Exp (S n)
close_exp_wrt_exp_rec k n1 x1 e1 =
  case e1 of
    Var_f x2 -> if (x1 == x2) then (Var_b n1) else (Var_f x2)
    -- variables that are greater than the binding level n1 need to be incremented
    -- because we are adding another binding
    Var_b n2 -> Var_b (cmpIdx n1 n2)
    Abs b -> Abs (bind (SS k) (close_exp_wrt_exp_rec (SS k) (FS n1) x1 (unbind b)))
    -- Abs (Bind (s1 :: Sub Exp m n) (b :: Exp (S m))) -> undefined
    -- here if s1 maps Var_b n1 to Var_f x1 then we can cancel the close out.
    App e2 e3 -> App (close_exp_wrt_exp_rec k n1 x1 e2) (close_exp_wrt_exp_rec k n1 x1 e3)

close :: IdInt -> Exp Z -> Bind Exp Z
close x e = bind SZ (close_exp_wrt_exp_rec SZ FZ x e)

impl :: LambdaImpl
impl =
  LambdaImpl
    { impl_name = "LocallyNamelessTyped",
      impl_fromLC = toDB,
      impl_toLC = fromDB,
      impl_nf = nfd,
      impl_nfi = nfi,
      impl_aeq = aeq
    }

{-
toDB :: LC.LC IdInt -> DB Z
toDB = to []
  where to :: [(IdInt, Idx n)] -> LC IdInt ->  DB n
        to vs (Var v)   = DVar (fromJust (lookup v vs))
        to vs (Lam v b) = DLam (bind b') where
             b' = to ((v,FZ):mapSnd FS vs) b
        to vs (App f a) = DApp (to vs f) (to vs a)
-

fromDB :: DB n -> LC IdInt
fromDB = from firstBoundId
  where
    from :: IdInt -> DB n -> LC IdInt
    from (IdInt n) (DVar i)
      | toInt i < 0 = Var (IdInt $ toInt i)
      | toInt i >= n = Var (IdInt $ toInt i)
      | otherwise = Var (IdInt (n - (toInt i) -1))
    from n (DLam b) = Lam n (from (succ n) (unbind b))
    from n (DApp f a) = App (from n f) (from n a)
-}

toDB :: LC.LC IdInt -> Exp Z
toDB = to SZ []
  where
    to :: SNat n -> [(IdInt, Idx n)] -> LC.LC IdInt -> Exp n
    to k vs (LC.Var v@(IdInt i)) = maybe (Var_f v) Var_b (lookup v vs)
    to k vs (LC.Lam x b) = Abs (bind k b')
      where
        b' = to (SS k) ((x, FZ) : mapSnd FS vs) b
    to k vs (LC.App f a) = App (to k vs f) (to k vs a)

mapSnd :: (a -> b) -> [(c, a)] -> [(c, b)]
mapSnd f = map (\(v, i) -> (v, f i))

fromDB :: Exp n -> LC.LC IdInt
fromDB = from firstBoundId
  where
    from :: IdInt -> Exp n -> LC.LC IdInt
    from n (Var_f v) = LC.Var v
    from (IdInt n) (Var_b i)
      | toInt i < 0 = LC.Var (IdInt $ toInt i)
      | toInt i >= n = LC.Var (IdInt $ toInt i)
      | otherwise = LC.Var (IdInt (n - (toInt i) -1))
    from n (Abs b) = LC.Lam n (from (succ n) (unbind b))
    from n (App f a) = LC.App (from n f) (from n a)

aeq :: Exp n -> Exp n -> Bool
aeq (Var_b i) (Var_b j) = i == j
aeq (Var_f i) (Var_f j) = i == j
aeq (Abs a) (Abs b) = aeq (unbind a) (unbind b)
aeq (App a b) (App c d) = aeq a c && aeq b d

instance NFData (Exp n) where
  rnf (Var_b i) = rnf i
  rnf (Var_f i) = rnf i
  rnf (Abs b) = rnf b
  rnf (App a b) = rnf a `seq` rnf b

-- no bound variables to weaken.
weaken :: forall m n. Exp n -> Exp (Plus n m)
weaken = Unsafe.unsafeCoerce

{-
weaken (Var_b i) = Var_b (weakenIdx @m i)
weaken (Var_f x) = Var_f x
weaken (Abs (Bind ss a)) = Abs (Bind (weakenSubst @m ss) (weaken @m a))
weaken (App a b) = App (weaken @m a) (weaken @m b)

weakenIdx :: forall m n. Idx n -> Idx (Plus n m)
weakenIdx FZ = FZ
weakenIdx (FS n) = FS (weakenIdx @m n)

weakenSubst :: forall p m n. Sub Exp m n -> Sub Exp (Plus m p) (Plus n p)
weakenSubst (Inc x) = Unsafe.unsafeCoerce $ Inc x
weakenSubst (Cons a ss) = Cons (weaken @p a) (weakenSubst @p ss)
weakenSubst (s1 :<> s2) = weakenSubst @p s1 :<> weakenSubst @p s2
-}

-- free variable substitution
subst :: Exp Z -> IdInt -> Exp Z -> Exp Z
subst u y e = subst0 SZ e
  where
    subst0 :: forall n. SNat n -> Exp n -> Exp n
    subst0 k e = case e of
      (Var_b n) -> Var_b n
      (Var_f x) -> (if x == y then weaken @n u else (Var_f x))
      (Abs b) -> Abs (bind k (subst0 (SS k) (unbind b)))
      (App e1 e2) -> App (subst0 @n k e1) (subst0 @n k e2)

fv :: Exp n -> Set IdInt
fv e =
  case e of
    (Var_b nat) -> Set.empty
    (Var_f x) -> Set.singleton x
    (Abs b) -> fv (unbind b)
    (App e1 e2) -> fv e1 `Set.union` fv e2

{-
open_exp_wrt_exp_rec :: Int -> Exp -> Exp -> Exp
open_exp_wrt_exp_rec k u e =
  case e of
    (Var_b n) ->
      case compare n k of
        LT -> Var_b n
        EQ -> u
        GT -> Var_b (n - 1)
    (Var_f x) -> Var_f x
    (Abs e) -> Abs (openBindRec (k + 1) u e)
    (App e1 e2) ->
      App
        (open_exp_wrt_exp_rec k u e1)
        (open_exp_wrt_exp_rec k u e2)

open_exp_wrt_map_rec :: IM.IntMap IdInt -> Exp -> Exp
open_exp_wrt_map_rec k e =
  case e of
    (Var_b n) ->
      case compare n k of
        LT -> Var_b n
        EQ -> u
        GT -> Var_b (n - 1)
    (Var_f x) -> Var_f x
    (Abs e) -> Abs (openRec (k + 1) e)
    -- need to increment the domain of all
    (App e1 e2) ->
      App
        (open_exp_wrt_map_rec k e1)
        (open_exp_wrt_map_rec k e2)

close_exp_wrt_exp_rec :: Int -> IdInt -> Exp -> Exp
close_exp_wrt_exp_rec n1 x1 e1 =
  case e1 of
    Var_f x2 -> if (x1 == x2) then (Var_b n1) else (Var_f x2)
    Var_b n2 -> if (n2 < n1) then (Var_b n2) else (Var_b (1 + n2))
    Abs e2 -> Abs (closeBindRec (1 + n1) x1 e2)
    App e2 e3 -> App (close_exp_wrt_exp_rec n1 x1 e2) (close_exp_wrt_exp_rec n1 x1 e3)
-}

type N a = State IdInt a

newVar :: (MonadState IdInt m) => m IdInt
newVar = do
  i <- get
  put (succ i)
  return i

nfd :: Exp Z -> Exp Z
nfd e = State.evalState (nf' e) firstBoundId

nf' :: Exp Z -> N (Exp Z)
nf' e@(Var_f _) = return e
nf' e@(Var_b _) = error "should not reach this"
nf' (Abs b) = do
  x <- newVar
  b' <- nf' (open b (Var_f x))
  return $ Abs (close x b')
nf' (App f a) = do
  f' <- whnf f
  case f' of
    Abs b -> nf' (open b a)
    _ -> App <$> nf' f' <*> nf' a

-- Compute the weak head normal form.
whnf :: Exp Z -> N (Exp Z)
whnf e@(Var_f _) = return e
whnf e@(Var_b _) = error "BUG"
whnf e@(Abs _) = return e
whnf (App f a) = do
  f' <- whnf f
  case f' of
    (Abs b) -> whnf (open b a)
    _ -> return $ App f' a

-- Fueled version

nfi :: Int -> Exp Z -> Maybe (Exp Z)
nfi n e = State.evalStateT (nfi' n e) firstBoundId

type NM a = State.StateT IdInt Maybe a

nfi' :: Int -> (Exp Z) -> NM (Exp Z)
nfi' 0 _ = State.lift Nothing
nfi' n e@(Var_f _) = return e
nfi' n e@(Var_b _) = error "should not reach this"
nfi' n (Abs e) = do
  x <- newVar
  e' <- nfi' (n - 1) (open e (Var_f x))
  return $ Abs (close x e')
nfi' n (App f a) = do
  f' <- whnfi (n - 1) f
  case f' of
    Abs b -> nfi' (n - 1) (open b a)
    _ -> App <$> nfi' (n - 1) f' <*> nfi' (n -1) a

-- Compute the weak head normal form.
whnfi :: Int -> Exp Z -> NM (Exp Z)
whnfi 0 _ = State.lift Nothing
whnfi n e@(Var_f _) = return e
whnfi n e@(Var_b _) = error "BUG"
whnfi n e@(Abs _) = return e
whnfi n (App f a) = do
  f' <- whnfi (n -1) f
  case f' of
    (Abs b) -> whnfi (n -1) (open b a)
    _ -> return $ App f' a
{-# LANGUAGE DefaultSignatures #-}

-- | Binding library
module Support.SubstOpt
  ( VarC (..),
    AlphaC (..),
    SubstC (..),
    Var (..),
    prettyVar,
    substBvVar,
    multiSubstBvVar,
    substFvVar,
    Bind,
    bind,
    unbind,
    instantiate,
    open,
    close,
    GAlpha (..),
    GSubst (..),
  )
where

import qualified Control.Monad.State as State
import qualified Data.IntMap as IM
import Data.List (elemIndex)
import qualified Data.Set as S
import GHC.Generics
import GHC.Stack
import Util.IdInt (IdInt (..), firstBoundId)
import Util.Impl (LambdaImpl (..))
import Util.Imports hiding (S, from, to)
import qualified Util.Lambda as LC

-------------------------------------------------------------------

-- | Type class of syntactic forms that contain variable constructors
class VarC a where
  var :: Var -> a

  isvar :: a -> Maybe Var
  isvar _ = Nothing
  {-# INLINE isvar #-}

-- | Type for syntactic forms
class AlphaC a where
  -- | calculate the free variables of a term
  fv :: a -> Set IdInt
  default fv :: (Generic a, GAlpha (Rep a)) => a -> Set IdInt
  fv x = gfv (from x)
  {-# INLINE fv #-}

  -- | replace bound variables (starting at k) with a list of free variables (i.e. [IdInt])
  -- NOTE: the term we are replacing into may not be locally closed
  multi_open_rec :: Int -> [Var] -> a -> a
  default multi_open_rec :: (Generic a, GAlpha (Rep a)) => Int -> [Var] -> a -> a
  multi_open_rec k vs x = to (gmulti_open_rec k vs (from x))

  -- | replace free variables (noted as "IdInt") with their respective bound variables
  -- starting at index k
  multi_close_rec :: Int -> [IdInt] -> a -> a
  default multi_close_rec :: (Generic a, GAlpha (Rep a)) => Int -> [IdInt] -> a -> a
  multi_close_rec k vs x = to (gmulti_close_rec k vs (from x))
  {-# INLINE multi_close_rec #-}

-- | Type class for substitution functions
class AlphaC a => SubstC b a where
  -- | substitute for multiple free variables
  -- multi_subst_fv :: [b] -> [IdInt] -> a -> a

  -- | substitute for multiple bound variables (starting at index k)
  multi_subst_bv :: Int -> [b] -> a -> a
  default multi_subst_bv :: (Generic a, VarC b, GSubst b (Rep a), a ~ b) => Int -> [b] -> a -> a
  multi_subst_bv k vs x =
    case isvar x of
      Just v -> multiSubstBvVar k vs v
      Nothing -> to (gmulti_subst_bv k vs (from x))
  {-# INLINE multi_subst_bv #-}

--------------------------------------------------------------

-- | Variables, bound and free
data Var = B Int | F IdInt deriving (Generic, Eq, Show)

-- | Display the variable without the outermost constructor
prettyVar :: Var -> String
prettyVar (B i) = "b" ++ show i
prettyVar (F x) = show x

instance NFData Var

instance VarC Var where
  var = id
  isvar x = Just x

instance AlphaC Var where
  fv (B _) = S.empty
  fv (F x) = S.singleton x
  {-# INLINE fv #-}

  --bv (B i) = S.singleton i
  --bv (F _) = S.empty

  multi_close_rec k xs (F x) =
    case elemIndex x xs of
      Just n -> B (n + k)
      Nothing -> F x
  multi_close_rec _k _xs (B n2) = (B n2)
  {-# INLINE multi_close_rec #-}

  multi_open_rec _k _ (F x) = F x
  multi_open_rec k vs (B i)
    | i >= k && i - k < length vs = vs !! (i - k)
    | otherwise = B i
  {-# INLINE multi_open_rec #-}

-- We need this instance for the generic version
-- but we should *never* use it
-- NB: may make sense to include overlapping instances
-- b/c the SubstC Var Var instance does make sense.
instance SubstC b Var where
  multi_subst_bv _k _ = error "BUG: should not reach here"
  {-# INLINE multi_subst_bv #-}

-- | multi substitution for a single bound variable, starting at index k
-- leaves all other variables alone
multiSubstBvVar :: VarC a => Int -> [a] -> Var -> a
multiSubstBvVar _ _ (F x) = var (F x)
multiSubstBvVar k vs (B i)
  | i >= k && i - k < length vs = vs !! (i - k)
  | otherwise = var (B i)
{-# INLINEABLE multiSubstBvVar #-}

substBvVar :: VarC a => a -> Var -> a
substBvVar u = multiSubstBvVar 0 [u]

-- | single substitution for a single free variable
substFvVar :: VarC a => a -> IdInt -> Var -> a
substFvVar _ _ (B n) = var (B n)
substFvVar u y (F x) = if x == y then u else (var (F x))
{-# INLINEABLE substFvVar #-}

-------------------------------------------------------------------

-- Caching open/close at binders.
-- To speed up this implementation, we delay the execution of subst_bv / open / close
-- in a binder so that multiple traversals can fuse together

data Bind a where
  Bind :: !a -> Bind a
  BindSubstBv :: !Int -> ![a] -> !a -> Bind a
  BindOpen :: !Int -> ![Var] -> !a -> Bind a
  BindClose :: !Int -> ![IdInt] -> !a -> Bind a
  deriving (Generic, Show)

instance (NFData a) => NFData (Bind a)

instance (Eq a, SubstC a a, Show a) => Eq (Bind a) where
  b1 == b2 = unbind b1 == unbind b2

-- | create a binding by "abstracting a variable"
bind :: a -> Bind a
bind = Bind
{-# INLINEABLE bind #-}

unbind :: (SubstC a a, Show a) => Bind a -> a
unbind b =
  go b
  where
    go (Bind a) = a
    go (BindSubstBv k ss a) = multi_subst_bv (k + 1) ss a
    go (BindOpen k ss a) = multi_open_rec (k + 1) ss a
    go (BindClose k vs a) = multi_close_rec k vs a
{-# INLINEABLE unbind #-}

instance (SubstC a a, Show a) => AlphaC (Bind a) where
  {-# SPECIALIZE instance (SubstC a a, Show a) => AlphaC (Bind a) #-}
  fv :: Bind a -> Set IdInt
  fv b = fv (unbind b)
  {-# INLINE fv #-}

  multi_open_rec _k vn (BindOpen l vm b) = BindOpen l (vm <> vn) b
  multi_open_rec k vn b = BindOpen k vn (unbind b)
  {-# INLINE multi_open_rec #-}

  multi_close_rec _k xs (BindClose k0 ys a) = (BindClose k0 (ys <> xs) a)
  multi_close_rec k xs b = (BindClose (k + 1) xs (unbind b))
  {-# INLINE multi_close_rec #-}

instance (SubstC a a, Show a) => SubstC a (Bind a) where
  {-# SPECIALIZE instance (SubstC a a, Show a) => SubstC a (Bind a) #-}
  multi_subst_bv _k vn (BindSubstBv l vm b) = BindSubstBv l (vm <> vn) b
  multi_subst_bv k vn b = BindSubstBv k vn (unbind b)
  {-# INLINE multi_subst_bv #-}

-- | Note: in this case, the binding should be localy closed
instantiate :: (SubstC a a, Show a) => Bind a -> a -> a
instantiate (BindSubstBv k vs e) u = multi_subst_bv k (u : vs) e
instantiate b u = multi_subst_bv 0 [u] (unbind b)
{-# INLINEABLE instantiate #-}

-----------------------------------------------------------------

open :: SubstC a a => Show a => Bind a -> Var -> a
open (BindOpen k vs e) x = multi_open_rec k (x : vs) e
open b x = multi_open_rec 0 [x] (unbind b)
{-# INLINEABLE open #-}

close :: Show a => IdInt -> a -> Bind a
close x e = BindClose 0 [x] e
{-# INLINEABLE close #-}

---------------------------------------------------------------------

class GAlpha f where
  gfv :: f a -> Set IdInt
  gmulti_open_rec :: Int -> [Var] -> f a -> f a
  gmulti_close_rec :: Int -> [IdInt] -> f a -> f a

class GSubst b f where
  gmulti_subst_bv :: Int -> [b] -> f a -> f a

-------------------------------------------------------------------

-- | Generic instances for substitution
instance (SubstC b c) => GSubst b (K1 i c) where
  gmulti_subst_bv k vs (K1 c) = K1 (multi_subst_bv k vs c)
  {-# INLINE gmulti_subst_bv #-}

instance GSubst b U1 where
  gmulti_subst_bv _k _v U1 = U1
  {-# INLINE gmulti_subst_bv #-}

instance GSubst b f => GSubst b (M1 i c f) where
  gmulti_subst_bv k vs = M1 . gmulti_subst_bv k vs . unM1
  {-# INLINE gmulti_subst_bv #-}

instance GSubst b V1 where
  gmulti_subst_bv _k _vs = id
  {-# INLINE gmulti_subst_bv #-}

instance (GSubst b f, GSubst b g) => GSubst b (f :*: g) where
  gmulti_subst_bv k vs (f :*: g) = gmulti_subst_bv k vs f :*: gmulti_subst_bv k vs g
  {-# INLINE gmulti_subst_bv #-}

instance (GSubst b f, GSubst b g) => GSubst b (f :+: g) where
  gmulti_subst_bv k vs (L1 f) = L1 $ gmulti_subst_bv k vs f
  gmulti_subst_bv k vs (R1 g) = R1 $ gmulti_subst_bv k vs g
  {-# INLINE gmulti_subst_bv #-}

instance SubstC b Int where
  multi_subst_bv _k _ = id
  {-# INLINE multi_subst_bv #-}

instance SubstC b Bool where
  multi_subst_bv _k _ = id
  {-# INLINE multi_subst_bv #-}

instance SubstC b () where
  multi_subst_bv _k _ = id
  {-# INLINE multi_subst_bv #-}

instance SubstC b Char where
  multi_subst_bv _k _ = id
  {-# INLINE multi_subst_bv #-}

instance (Generic a, AlphaC a, GSubst b (Rep [a])) => SubstC b [a] where
  multi_subst_bv k xs x = to $ gmulti_subst_bv k xs (from x)
  {-# INLINE multi_subst_bv #-}

instance (Generic a, AlphaC a, GSubst b (Rep (Maybe a))) => SubstC b (Maybe a) where
  multi_subst_bv k xs x = to $ gmulti_subst_bv k xs (from x)
  {-# INLINE multi_subst_bv #-}

instance (Generic (Either a1 a2), AlphaC (Either a1 a2), GSubst b (Rep (Either a1 a2))) => SubstC b (Either a1 a2) where
  multi_subst_bv k xs x = to $ gmulti_subst_bv k xs (from x)
  {-# INLINE multi_subst_bv #-}

instance (Generic (a, b), AlphaC (a, b), GSubst c (Rep (a, b))) => SubstC c (a, b) where
  multi_subst_bv k xs x = to $ gmulti_subst_bv k xs (from x)
  {-# INLINE multi_subst_bv #-}

instance
  ( Generic (a, b, d),
    AlphaC (a, b, d),
    GSubst c (Rep (a, b, d))
  ) =>
  SubstC c (a, b, d)
  where
  multi_subst_bv k xs x = to $ gmulti_subst_bv k xs (from x)
  {-# INLINE multi_subst_bv #-}

----------------------------------------------------------------
-- Generic instances for Alpha

instance (AlphaC c) => GAlpha (K1 i c) where
  gfv (K1 c) = (fv c)
  gmulti_open_rec x xs (K1 c) = K1 (multi_open_rec x xs c)
  gmulti_close_rec x xs (K1 c) = K1 (multi_close_rec x xs c)
  {-# INLINE gfv #-}
  {-# INLINE gmulti_open_rec #-}
  {-# INLINE gmulti_close_rec #-}

instance GAlpha U1 where
  gfv U1 = S.empty
  gmulti_open_rec _ _ = id
  gmulti_close_rec _ _ = id
  {-# INLINE gfv #-}
  {-# INLINE gmulti_close_rec #-}

instance GAlpha f => GAlpha (M1 i c f) where
  gfv = gfv . unM1
  gmulti_open_rec x xs = M1 . gmulti_open_rec x xs . unM1
  gmulti_close_rec x xs = M1 . gmulti_close_rec x xs . unM1
  {-# INLINE gfv #-}
  {-# INLINE gmulti_close_rec #-}

instance GAlpha V1 where
  gfv _s = S.empty
  gmulti_open_rec _ _ = id
  gmulti_close_rec _ _ = id
  {-# INLINE gfv #-}
  {-# INLINE gmulti_close_rec #-}

instance (GAlpha f, GAlpha g) => GAlpha (f :*: g) where
  gfv (f :*: g) = gfv f `S.union` gfv g
  gmulti_open_rec x xs (f :*: g) =
    gmulti_open_rec x xs f :*: gmulti_open_rec x xs g
  gmulti_close_rec x xs (f :*: g) =
    gmulti_close_rec x xs f :*: gmulti_close_rec x xs g
  {-# INLINE gfv #-}
  {-# INLINE gmulti_close_rec #-}

instance (GAlpha f, GAlpha g) => GAlpha (f :+: g) where
  gfv (L1 f) = gfv f
  gfv (R1 g) = gfv g
  gmulti_open_rec x xs (L1 f) = L1 $ gmulti_open_rec x xs f
  gmulti_open_rec x xs (R1 g) = R1 $ gmulti_open_rec x xs g
  gmulti_close_rec x xs (L1 f) = L1 $ gmulti_close_rec x xs f
  gmulti_close_rec x xs (R1 g) = R1 $ gmulti_close_rec x xs g
  {-# INLINE gfv #-}
  {-# INLINE gmulti_close_rec #-}

instance AlphaC Int where
  fv _ = S.empty
  multi_open_rec _ _ = id
  multi_close_rec _ _ = id
  {-# INLINE fv #-}
  {-# INLINE multi_close_rec #-}

instance AlphaC Bool where
  fv _ = S.empty
  multi_open_rec _ _ = id
  multi_close_rec _ _ = id
  {-# INLINE fv #-}
  {-# INLINE multi_close_rec #-}

instance AlphaC () where
  fv _ = S.empty
  multi_open_rec _ _ = id
  multi_close_rec _ _ = id
  {-# INLINE fv #-}
  {-# INLINE multi_close_rec #-}

instance AlphaC Char where
  fv _ = S.empty
  multi_open_rec _ _ = id
  multi_close_rec _ _ = id
  {-# INLINE fv #-}
  {-# INLINE multi_close_rec #-}

instance AlphaC String where
  fv _ = S.empty
  multi_open_rec _ _ = id
  multi_close_rec _ _ = id
  {-# INLINE fv #-}
  {-# INLINE multi_close_rec #-}

instance AlphaC a => AlphaC [a]

instance AlphaC a => AlphaC (Maybe a)

instance (AlphaC a1, AlphaC a2) => AlphaC (Either a1 a2)

instance (AlphaC a, AlphaC b) => AlphaC (a, b)

instance (AlphaC a, AlphaC b, AlphaC d) => AlphaC (a, b, d)

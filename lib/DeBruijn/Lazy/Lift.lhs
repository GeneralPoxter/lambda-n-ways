This version is an adaptation of Lennart's Debruijn implementation.
Instead of adjusting the indices of variables at each occurrence of the term, 
it lifts the substitution as it goes under each binder.

Compare this version to Lennart's version and the one called "Cornell".

> module DeBruijn.Lazy.Lift(impl, toDB, fromDB, nfd, nfi) where
> import Data.List(elemIndex)
> import Util.Lambda
> import Util.IdInt
> import Control.DeepSeq
> import qualified Util.Stats as Stats

> import Util.Impl

> impl :: LambdaImpl
> impl = LambdaImpl {
>             impl_name   = "DeBruijn.Lazy.Lift"
>           , impl_fromLC = toDB
>           , impl_toLC   = fromDB
>           , impl_nf     = nfd
>           , impl_nfi    = nfi
>           , impl_aeq    = (==)
>        }


Variables are represented by their binding depth, i.e., how many
$\lambda$s out the binding $\lambda$ is.  

> data DB = DVar Int | DLam DB | DApp DB DB
>   deriving (Eq)

> instance NFData DB where
>    rnf (DVar i) = rnf i
>    rnf (DLam d) = rnf d
>    rnf (DApp a b) = rnf a `seq` rnf b

Computing the normal form proceeds as usual.

> nfd :: DB -> DB
> nfd e@(DVar _) = e
> nfd (DLam e) = DLam (nfd e)
> nfd (DApp f a) =
>     case whnf f of
>         DLam b -> nfd (instantiate b a)
>         f' -> DApp (nfd f') (nfd a)

Compute the weak head normal form.

> whnf :: DB -> DB
> whnf e@(DVar _) = e
> whnf e@(DLam _) = e
> whnf (DApp f a) =
>     case whnf f of
>         DLam b -> whnf (instantiate b a)
>         f' -> DApp f' a


Bounded versions

> nfi :: Int -> DB -> Stats.M DB
> nfi 0 _e = Stats.done
> nfi _n e@(DVar _) = return e
> nfi n (DLam b) = DLam <$> nfi (n-1) b
> nfi n (DApp f a) = do
>     f' <- whnfi (n-1) f 
>     case f' of
>         DLam b -> Stats.count >> nfi (n-1) (instantiate b a)
>         _ -> DApp <$> nfi n f' <*> nfi n a

> whnfi :: Int -> DB -> Stats.M DB
> whnfi 0 _e = Stats.done
> whnfi _n e@(DVar _) = return e
> whnfi _n e@(DLam _) = return e
> whnfi n (DApp f a) = do
>     f' <- whnfi (n-1) f 
>     case whnf f' of
>         DLam b -> Stats.count >> whnfi (n-1) (instantiate b a)
>         _ -> return $ DApp f' a


> instantiate :: DB -> DB -> DB
> instantiate b a = subst (sub a) b
> {-# INLINE instantiate #-}

If we are going to be adjusting the terms in the substitution, 
it is important to do that *lazily*. We don't want to adjust terms that 
aren't actually used in the expression.

> data Sub = Sub {-# UNPACK #-} !Int DB
> sub :: DB -> Sub 
> sub a = Sub 0 a
> {-# INLINE sub #-}

> subst :: Sub -> DB -> DB
> subst s (DVar i) = apply s i
>
> subst s (DLam e) = DLam (subst (lift s) e)
> subst s (DApp f a) = DApp (subst s f) (subst s a)

> adjust :: Int -> DB -> Int -> DB
> adjust o e@(DVar j) n | j >= n = DVar (j+o)
>                       | otherwise = e
> adjust o (DLam e) n = DLam (adjust o e (n+1))
> adjust o (DApp f a) n = DApp (adjust o f n) (adjust o a n)

> lift :: Sub -> Sub
> lift (Sub o b) = Sub (o+1) (adjust 1 b 0) 
> {-# INLINE lift #-}

> apply :: Sub -> Int -> DB
> apply (Sub o a) i
>  | i == o    = a   -- already adjusted in lift
>  | i >  o    = DVar (i-1)
>  | otherwise = DVar i
> {-# INLINE apply #-}



Convert to deBruijn indicies.  Do this by keeping a list of the bound
variable so the depth can be found of all variables.  Do not touch
free variables.

> toDB :: LC IdInt -> DB
> toDB = to []
>   where to vs (Var v@(IdInt i)) = maybe (DVar i) DVar (elemIndex v vs)
>         to vs (Lam x b) = DLam (to (x:vs) b)
>         to vs (App f a) = DApp (to vs f) (to vs a)

Convert back from deBruijn to the LC type.

> fromDB :: DB -> LC IdInt
> fromDB = from firstBoundId
>   where from (IdInt n) (DVar i) | i < 0     = Var (IdInt i)
>                                 | i >= n    = Var (IdInt i)
>                                 | otherwise = Var (IdInt (n-i-1))
>         from n (DLam b) = Lam n (from (succ n) b)
>         from n (DApp f a) = App (from n f) (from n a)

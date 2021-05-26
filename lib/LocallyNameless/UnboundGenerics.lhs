> {-# LANGUAGE DeriveGeneric #-}
> {-# LANGUAGE MultiParamTypeClasses
>           , FlexibleContexts
>           , FlexibleInstances
>           , TypeFamilies
>           , GADTs
>           , ScopedTypeVariables
>  #-}
> {-# OPTIONS_GHC -fcross-module-specialise #-}

> module LocallyNameless.UnboundGenerics(impl) where

> import qualified Lambda as L
> import IdInt
>
> import qualified Control.DeepSeq as DS
> import GHC.Generics(Generic)
> import Unbound.Generics.LocallyNameless as U
> import Unbound.Generics.PermM as U

> import Impl

> data Exp = Var (U.Name Exp)
>          | Lam (U.Bind (U.Name Exp) Exp)
>          | App Exp Exp
>  deriving (Show, Generic)
>
> instance DS.NFData Exp where
>    rnf (Var n)     = DS.rnf n
>    rnf (Lam bnd)   = DS.rnf bnd
>    rnf (App e1 e2) = DS.rnf e1 `seq` DS.rnf e2



> impl :: LambdaImpl
> impl = LambdaImpl {
>             impl_name   = "UnboundG"
>           , impl_fromLC = toDB
>           , impl_toLC   = fromDB
>           , impl_nf     = nfu
>           , impl_nfi    = error "nfi unimplementd for unbound"
>           , impl_aeq    = aeqd
>        }


With representation types, the default implementation of Alpha
provides alpha-equivalence and free variable calculation.

> aeq :: L.LC IdInt -> L.LC IdInt -> Bool
> aeq x y = U.aeq (toDB x) (toDB y)

> aeqd :: Exp -> Exp -> Bool
> aeqd = U.aeq

> instance U.Alpha Exp


-- | The subst class uses generic programming to implement capture
-- avoiding substitution. It just needs to know where the variables
-- are.

> instance U.Subst Exp Exp where
>   isvar (Var x) = Just (U.SubstName x)
>   isvar _       = Nothing


> nfu :: Exp -> Exp
> nfu = U.runFreshM . nfd

> nf :: L.LC IdInt -> L.LC IdInt
> nf = fromDB . nfu . toDB

Computing the normal form proceeds as usual.

> nfd :: Exp -> U.FreshM Exp
> nfd e@(Var _) = return e
> nfd (Lam e)   =
>   do (x, e') <- U.unbind e
>      e1 <- nfd e'
>      return $ Lam (U.bind x e1)
> nfd (App f a) = do
>     f' <- whnf f 
>     case f' of
>         Lam b -> do (x, b') <- U.unbind b
>                     nfd (U.subst x a b')
>         _ -> App <$> nfd f' <*> nfd a

Compute the weak head normal form.

> whnf :: Exp -> U.FreshM Exp
> whnf e@(Var _) = return e
> whnf e@(Lam _) = return e
> whnf (App f a) = do
>     f' <- whnf f
>     case f' of
>         Lam b -> do (x, b') <- U.unbind b
>                     whnf (U.subst x a b')
>         _ -> return $ App f' a


Convert from LC type to DB type (try to do this in linear time??)

> toDB :: L.LC IdInt -> Exp
> toDB = to
>   where to :: L.LC IdInt -> Exp
>         to (L.Var v)   = Var (i2n v)
>         to (L.Lam x b) = Lam (U.bind (i2n x) (to b))
>         to (L.App f a) = App (to f)(to a)
>


Convert back from deBruijn to the LC type.

> n2i :: U.Name Exp -> IdInt
> n2i n = IdInt (fromInteger (name2Integer n))
>
> i2n :: IdInt -> U.Name Exp
> i2n (IdInt x) = s2n (show x)

> fromDB :: Exp -> L.LC IdInt
> fromDB = U.runFreshM . from 
>   where from :: Exp -> U.FreshM (L.LC IdInt)
>         from (Var n)   = return $ L.Var (n2i n)
>         from (Lam b)   = do
>             (x,a) <- unbind b
>             L.Lam (n2i x) <$> from a
>         from (App f a) = L.App <$> from f <*> from a 




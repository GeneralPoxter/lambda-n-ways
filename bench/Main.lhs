> {-# LANGUAGE BangPatterns #-}
> {-# LANGUAGE RecordWildCards #-}
> 
> {- | Entry point for the benchmarking application. 
>      
>  -}
> module Main where
> import qualified Data.List as List
> import Misc
> import Lambda
> import IdInt
> import Impl
> import Suite
> import qualified Lennart.Simple as Simple
> import qualified Lennart.Unique as Unique
> import Test.QuickCheck

> import Criterion.Main
> import Control.DeepSeq
>
> 

> data Bench =
>   forall a. Bench String (a -> ()) a
>   | BGroup String [Bench]


> -- | Benchmarks for timing conversion from named representation to internal representation
> conv_bs :: LC IdInt -> [Bench]
> conv_bs lc = conv_bss [lc]

> -- | Benchmarks for timing conversion from named representation to internal representation
> conv_bss :: [LC IdInt] -> [Bench]
> conv_bss lcs = map impl2nf impls where
>   impl2nf :: LambdaImpl -> Bench
>   impl2nf LambdaImpl {..} =
>     Bench impl_name (rnf . map (rnf . impl_fromLC)) lcs 


> -- | Benchmarks for timing normal form calculation (single term)
> nf_bs :: LC IdInt -> [Bench]
> nf_bs lc = map impl2nf impls where
>   impl2nf LambdaImpl {..} =
>     let! tm = force (impl_fromLC lc) in
>     Bench impl_name (rnf . impl_nf) tm

> -- | Benchmarks for timing normal form calculation (multiple terms)
> nf_bss :: String ->[LC IdInt] -> [Bench]
> nf_bss nm lcs = map impl2nf impls where
>   impl2nf LambdaImpl {..} =
>     let! tms = force (map impl_fromLC lcs) in
>     -- let  pairs = zip lcs (map impl_nf tms) in
>     Bench (impl_name <> "/" <> nm) (rnf . map impl_nf) tms

> -- | Benchmarks for timing normal form calculation (multiple terms)
> constructed_bss :: String ->[LC IdInt] -> [Bench]
> constructed_bss nm lcs = map impl2nf impls where
>   impl2nf LambdaImpl {..} =
>     let! tms = force (map impl_fromLC lcs) in
>     let benches = map (\(t,i) -> Bench (show i) (rnf . impl_nf) t) (zip tms [1..]) in
>     BGroup (impl_name <> "/" <> nm) benches


> -- benchmark for alpha-equivalence
> aeq_bs :: LC IdInt -> LC IdInt -> [Bench]
> aeq_bs lc1 lc2 = map impl2aeq impls where
>   impl2aeq LambdaImpl {..} =
>     let! tm1 = force (impl_fromLC lc1) in
>     let! tm2 = force (impl_fromLC lc2) in
>     Bench impl_name (\(x,y) -> rnf (impl_aeq x y)) (tm1,tm2)


> runBench :: Bench -> Benchmark
> runBench (Bench n f x) = bench n $ Criterion.Main.nf f x
> runBench (BGroup n bs) = bgroup n $ map runBench bs

> main :: IO ()
> main = do
>   tm <- getTerm "lams/lennart.lam"
>   let tm1 = toIdInt tm
>   return $! rnf tm1
>   let tm2 = toIdInt (Unique.fromUnique (Unique.toUnique tm1))
>   return $! rnf tm2
>   let! convs = conv_bs tm1
>   let! nfs   = nf_bss "" [tm1]
>   let! aeqs  = aeq_bs tm1 tm2
>   random_terms <- getTerms "lams/random.lam"
>   --random_terms <- getTerms "lams/lams100.lam"
>   let! rands = nf_bss "" random_terms
>   con_terms <- getTerms "lams/constructed20.lam"
>   let! cons = constructed_bss "con" con_terms
>   capt_terms <- getTerms "lams/capture10.lam"
>   let! capts = constructed_bss "capt" capt_terms
>   -- let runBench (Bench n f x) = bench n $ Criterion.Main.nf f x
>   defaultMain [
>     bgroup "rand" $ map runBench rands
>    , bgroup "conv" $ map runBench convs
>    , bgroup "nf"   $ map runBench nfs
>    , bgroup "aeq"  $ map runBench aeqs
>    , bgroup "con"  $ map runBench cons
>    , bgroup "capt" $ map runBench capts
>    ] 
>
>
>

The $\lambda$-expression in {\tt lennart.lam} computes
``{\tt factorial 6 == sum [1..37] + 17`factorial 6 == sum [1..37] + 17}'', but using Church numerals.

\mbox{}\\
\mbox{}\\
{\tt timing.lam:}
\begin{verbatim}
let False = \f.\t.f;
    True = \f.\t.t;
    if = \b.\t.\f.b f t;
    Zero = \z.\s.z;
    Succ = \n.\z.\s.s n;
    one = Succ Zero;
    two = Succ one;
    three = Succ two;
    isZero = \n.n True (\m.False);
    const = \x.\y.x;
    Pair = \a.\b.\p.p a b;
    fst = \ab.ab (\a.\b.a);
    snd = \ab.ab (\a.\b.b);
    fix = \ g. (\ x. g (x x)) (\ x. g (x x));
    add = fix (\radd.\x.\y. x y (\ n. Succ (radd n y)));
    mul = fix (\rmul.\x.\y. x Zero (\ n. add y (rmul n y)));
    fac = fix (\rfac.\x. x one (\ n. mul x (rfac n)));
    eqnat = fix (\reqnat.\x.\y. x (y True (const False)) (\x1.y False (\y1.reqnat x1 y1)));
    sumto = fix (\rsumto.\x. x Zero (\n.add x (rsumto n)));
    n5 = add two three;
    n6 = add three three;
    n17 = add n6 (add n6 n5);
    n37 = Succ (mul n6 n6);
    n703 = sumto n37;
    n720 = fac n6
in  eqnat n720 (add n703 n17)
\end{verbatim}

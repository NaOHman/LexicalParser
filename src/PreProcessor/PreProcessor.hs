{-# LANGUAGE NoMonomorphismRestriction, FlexibleContexts #-}
module PreProcessor.PreProcessor where

import Models.Program
import Types.Utils hiding (find)
import Control.Monad (foldM)
import Control.Monad.Trans
import Control.Monad.Trans.Either
import Control.Monad.State
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.List (find, sort, delete, (\\), nub, partition)
import Data.Maybe (isJust)
import Data.Char (isLower)
import GHC.Exts (groupWith)
import Data.Graph hiding (scc)
import Data.Graph.SCC

type PP a = State Int a

validate ts = evalState (preprocess ts) 0

splitBindings :: [Binding] -> [BindGroup]
splitBindings bs = reverse $ map splitImpl $ depGroups [] bs

splitImpl :: [Binding] -> BindGroup
splitImpl bs =
            let (es, is) = splitBinds bs
                eIds = map (\(i,_,_) -> i) es
                iGroups = depGroups eIds (map Impl is)
                iBinds = map (map (\(Impl tpl) -> tpl)) iGroups
            in (es, iBinds)
        

depGroups :: [Id] -> [Binding] -> [[Binding]]
depGroups ids bs = 
    let edges = map (findDeps ids) bs
        (dGraph, mapping, _) = graphFromEdges edges
        (components, _) = scc dGraph
        vertices = map snd components
        nodev (b,_,_) = b
    in map (map (nodev . mapping)) vertices
        
findDeps ids b@(Impl(i,e)) = (b, i, userVars e \\ (i:ids)) 
findDeps ids b@(Expl(i,_,e)) = (b, i, userVars e \\ (i:ids)) 

userVars :: Expr -> [Id]
userVars (Var i@(c:_)) 
    | isLower c = [i | i /= "print"]
    | otherwise = []
userVars (Abs (ps,e)) = userVars e \\ nub (concatMap pvar ps)
userVars (Ap e1 e2) = nub $ userVars e1 ++ userVars e2
userVars (Let bs e) = let ids = map bindingName bs
                          es  = map exprOf bs
                      in nub (userVars e ++ concatMap userVars es) \\ ids
userVars (Case e bs) = nub $ userVars e ++ concatMap (userVars . Abs) bs
userVars (Annot e _) = userVars e
userVars (Lit _) = []
-- userVars is undefined for overloaded expressions since
-- they should never be passed to this function

pvar (PVar v) = [v]
pvar (PAs v p) = v : pvar p
pvar (PCons _ ps) = nub $ concatMap pvar ps
pvar _ = []
                           
preprocess :: [Top] -> PP (ClassEnv, [Assump], [BindGroup], [Binding])
preprocess ts = do
    let (bnds, rdt, adt, bvs, imps) = splitTops ts
    (fbs', recCE) <- processRecs rdt
    (fbs, fieldCE) <- overload fbs'

    let (expl,impl) = splitBinds bnds
    (expl', overCE) <- overload expl
    bhCE <- makeCE bvs imps

    let constructors = concatMap dCstrs adt ++ concatMap dCstrs rdt 
        ce = M.unions [bhCE, overCE, recCE, fieldCE] 

        fassumps = bindingAssumps (fbs ++ overBinds bhCE ++ ceBinds ce)
        assumps = makeCstrAssumps constructors ++ fassumps

        impl' = map Impl impl
        consBinds = constrBinds constructors
        impBinds = ceBinds ce ++ fbs ++ consBinds
        binds = impl' ++ expl'  ++ overBinds bhCE

        aNames = concatMap dNames adt
        rNames = concatMap dNames rdt
        bNames = behaviorNames ce
        nNames = map bindingName (binds ++ impBinds)
        names = aNames ++ rNames ++ bNames ++ nNames
    unless (uniq names) (fail "Duplicate name found")
    fullAp (map dTCons adt ++ map dTCons rdt) binds
 
    {-mn <- genMain binds-}
    let (es,is) = splitBinds binds
    let eassumps = map (\(i,sc,_) -> i :>: sc) es
    return (ce, assumps, splitBindings binds, impBinds)

bindingAssumps = map (\(Expl (i,s,_)) -> i :>: s) 
constrBinds = map toBind 
    where toBind (n, s) = Expl (n, s, Var n)

makeCstrAssumps = map (uncurry (:>:))

overBinds :: ClassEnv -> [Binding]
overBinds = M.foldMapWithKey f
    where f i (_,_,os) = concatMap (unpack i) os

implName i qt = "$" ++ i ++  "#" ++ show qt

unpack :: Id -> Expl -> [Binding]
unpack cls (i, sc@(Forall k (q:=>t)), Over ps) = 
    let ([IsIn _ [TGen n]],qs) = partition qualFilter q
    in map (bnd n (Forall k (qs:=>t))) ps
    where qualFilter (IsIn i _) = i == cls
          bnd n sc (qt, ex) = 
              let sch = pInst qt n sc
              in Expl (implName i qt, sch, ex)

pInst (q:=>t) n (Forall ks (ps:=>st)) = 
    let ts = zipWith f ks [0..]
    in quantify (tv ts) ((q++ps) :=> inst ts st)
    where f k m
            | m == n = t
            | otherwise = TVar $ Tyvar (show m) k

ceBinds :: ClassEnv -> [Binding]
ceBinds = M.foldl f []
    where f as (_,_,bs) = as ++ map Expl bs

uniq :: Eq a => [a] -> Bool
uniq xs = uniq' xs []
    where uniq' [] _ = True
          uniq' (x:xs) ls = x `notElem` ls && uniq' xs (x:ls)

makeCE :: [Behavior] -> [Implementation] -> PP ClassEnv
makeCE bs is = do
    ce <- M.fromList <$> foldCBS bs
    unless (uniq $ stubNames ce) 
           (fail "Behavior methods must be unique")
    foldM addImp ce is

addImp :: ClassEnv -> Implementation -> PP ClassEnv
addImp ce (Im q t i ss) = do
   (sc,is,stbs) <- case M.lookup i ce of
             Just cls -> return cls
             Nothing -> fail $ "Behavior " ++ i ++ "Not Found"
   let inst = q :=> IsIn i [spine t] 
       bns = map fst ss
       sns = map (\(i,_,_) -> i) stbs
   unless (sort bns == sort sns) 
          (fail $ "Must implement stubs defined by " ++ i)
   let stbs' = foldl (addStub (q :=> (TCons $  getCons t))) stbs ss
   return (M.insert i (sc,inst:is, stbs') ce)

addStub :: Qual Type -> [Expl] -> (Id, Expr) -> [Expl] 
addStub qt stbs (sn, ex) = map add' stbs
    where add' (n, sc, Over bs)
              | n == sn = (n, sc, Over ((qt, ex) : bs))
              | otherwise = (n, sc, Over bs)

stubNames = map (\(i,_,_) -> i) . concatMap (\(_,_,o) -> o) . M.elems 
    
foldCBS = foldM f []
    where f bs b = (:bs) <$> toCB b (map fst bs)

toCB :: Behavior -> [Id] -> PP (Id, Class)
toCB (Bhvr q t n stbs) bs = do
    ss <- mapM sups q 
    return (n, (ss, [], map mkStub stbs))
    where mkStub (i, st) = let bt = spine t
                               sc = quantAll ([IsIn n [bt]] :=> st)
                           in (i, sc, Over [])
          sups (IsIn i _) = if i `elem` bs 
                then return i
                else fail "Super Behavior not yet defined"

spine (TAp t _) = spine t
spine t = t

processRecs :: [Rec] -> PP ([Expl], ClassEnv)
processRecs rs = do
    --break into inherited/noninherited datatypes
    (inhPairs, regs) <-  filterInherits rs
    let rfBind = concatMap fieldBinds regs
         
        --group inheritance pairs into classes
        classes = groupWith (tname . dTCons . fst) inhPairs

    -- turn those classes into bindings/behaviors
    (bs, cbs) <- unzip <$> mapM promote classes
    return (rfBind ++ concat bs, M.fromList cbs)

promote :: [(Rec,Rec)] -> PP ([Expl],(Id,Class))
promote rs@((sup,_):_) = do
    -- All the classes that inherit from a type
    let imps = sup : map snd rs
        -- parse a class binding
        (n,(s,i,stubs)) = makeSuperClass sup imps
    -- condense bindings
    (binds,stbs) <- foldM bindSup ([], stubs) imps
    return (binds, (n,(s,i,stbs)))

makeSuperClass :: Rec -> [Rec] -> (Id,Class)
makeSuperClass s@(Rec q t ss fs) impl =
    let name = '*' : consName t
        stubs = map (superStub name) fs
        supers = map (('*':) . consName) ss
        ts = map qualed impl
        insts = map (\(p:=>t) -> p :=> IsIn name [t]) ts
    in (name, (supers, insts, stubs))
    where superStub n (id,ft) = 
               let q =  [IsIn n [t]]
                   t' = [t] `mkFun` ft
               in (id,quantQual q t', Over [])


-- Return the list of overloaded field bindings and the
-- list of type-specific bindings
bindSup :: ([Expl],[Expl]) -> Rec -> PP ([Expl], [Expl])
bindSup (bs,stubs) r@(Rec q t _ ss) = do 
    let fbs = fieldBinds r
        (over,under) = split inStubs fbs
        --TODO VALIDATE THIS ASSUMPTION
        obs = map (\(i,_,e) -> (i,e)) over
    unless (length stubs == length over) 
           (fail "Must include all fields of super type")
    let stbs = foldl (addStub (q :=> t)) stubs obs
    {-return stbs-}
    return (under ++ bs, stbs)
    where inStubs (b,s,_) = isJust (find (\(i,_,_) -> i == b) stubs)

fieldBinds (Rec q t _ fs) = zipWith f fs [0..]
    where f (n, ft) i = let sch = quantQual q ([ft] `mkFun` t)
                        in (n, sch, Var ("#" ++ show i))


filterInherits :: [Rec] -> PP ([(Rec,Rec)],[Rec])
filterInherits rs = do (a,b,_) <- foldM f ([],[],[]) rs
                       let sups = map fst a
                           regs = [x | x <- b, x `notElem` sups]
                       return (a,regs)
    where f (is,ns,rs) r = if null (sups r)
              then return (is, r:ns, r:rs)
              else do impls <- mapM (findSup r rs) (sups r)
                      return (impls ++ is,ns, r:rs)
          findSup r rs s = case supDefined s rs of
              (Just sup) -> return (sup,r)
              Nothing  -> fail "Super class not defined"
          supDefined s = find (\x -> getCons s == dTCons x)


overload :: [(Id, Scheme, Expr)] -> PP ([Binding], ClassEnv)
overload bs = do
    let groups = groupExpl bs
        (under,over) = split ((1 ==) . length) groups
    return under
    ce <- M.unions <$> mapM overBehavior over
    let bnds = map Expl (concat under)
    return (bnds, ce)

overBehavior :: [Expl] -> PP ClassEnv
overBehavior bs@((i,_, _):_) = do
    pairs <- mapM bindPairs bs
    let cname = "_over_" ++ i
        v = TVar $ Tyvar "^var" Star
        sch = quantQual [IsIn cname [v]] v
        insts = map (makeInst cname . fst) pairs
        stubs =  [(i, sch, Over pairs)]
    return $ M.singleton cname ([], insts, stubs)
    where 
          makeInst cls (qs :=> t) = qs :=> IsIn cls [t]
          bindPairs (_, sc, ex) = if null (tv sc)
                then (do qt <- freshInst sc
                         return (qt,ex))
                else fail $ "Incomplete type signature for "++i

splitBinds = foldl f ([],[]) 
    where  f (es, is) (Expl e) = (e:es,is) 
           f (es, is) (Impl i) = (es,i:is)

freshInst :: Scheme -> PP (Qual Type)
freshInst (Forall ks qt) = do ts <- mapM newTVar ks
                              return (inst ts qt)

consName (TAp t _) = consName t
consName (TCons (Tycon n _)) = n

bindingName (Expl (i,_,_)) = i
bindingName (Impl (i,_)) = i

behaviorNames = M.keys

fullAp :: [Tycon] -> [Binding] -> PP ()
fullAp _ _ = return ()

genMain :: [Binding] -> PP Expr
genMain bs = do
    let (m, bs') = split (("main" ==) . bindingName) bs
    unless (length m == 1) (fail "Could not find main")
    return $ Let bs' (exprOf $ head m)
    
exprOf :: Binding -> Expr
exprOf (Impl (_,e)) = e
exprOf (Expl (_,_,e)) = e
    
newTVar k = do i <- get
               let v = "&var" ++ show i
               put (i + 1)
               return $ TVar $ Tyvar v k

splitTops :: [Top] -> ([Binding], [Rec], [Adt], [Behavior], [Implementation])
splitTops = foldl split ([],[],[],[],[])
    where split (bs, rs, as, cs, is) (Bind b) = (b:bs, rs, as, cs, is)
          split (bs, rs, as, cs, is) (RDT r) = (bs, r:rs, as, cs, is)
          split (bs, rs, as, cs, is) (ADT a) = (bs, rs, a:as, cs, is)
          split (bs, rs, as, cs, is) (Bvr b) = (bs, rs, as, b:cs, is)
          split (bs, rs, as, cs, is) (Imp i) = (bs, rs, as, cs, i:is)

tname (Tycon n _) = n
qualed (Rec q t _ _) = q :=> t

split p = foldl f ([],[])
    where f (as,bs) x = if p x then (x:as,bs) else (as,x:bs)

groupExpl = groupWith (\(n,_,_) -> n)
emptySch = Forall [Star] ([] :=> TGen 0)

{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE UndecidableInstances #-}
module Servant.API.TypeLevel where

import GHC.Exts(Constraint)
import Servant.API.Capture ( Capture, CaptureAll )
import Servant.API.ReqBody ( ReqBody )
import Servant.API.QueryParam ( QueryParam, QueryParams, QueryFlag )
import Servant.API.Header ( Header )
import Servant.API.Verbs ( Verb )
import Servant.API.Sub ( type (:>) )
import Servant.API.Alternative ( type (:<|>) )
#if MIN_VERSION_base(4,9,0)
import GHC.TypeLits (TypeError, ErrorMessage(..))
#endif

-- * API predicates

-- | Flatten API into a list of endpoints.
type family Endpoints api where
  Endpoints (a :<|> b) = AppendList (Endpoints a) (Endpoints b)
  Endpoints (e :> a)   = MapSub e (Endpoints a)
  Endpoints a = '[a]

-- ** Lax inclusion

-- | You may use this type family to tell the type checker that your custom
-- type may be skipped as part of a link. This is useful for things like
-- @'QueryParam'@ that are optional in a URI and do not affect them if they are
-- omitted.
--
-- >>> data CustomThing
-- >>> type instance IsElem' e (CustomThing :> s) = IsElem e s
--
-- Note that @'IsElem'@ is called, which will mutually recurse back to @'IsElem''@
-- if it exhausts all other options again.
--
-- Once you have written a @HasLink@ instance for @CustomThing@ you are ready to go.
type family IsElem' a s :: Constraint

-- | Closed type family, check if @endpoint@ is within @api@.
-- Uses @'IsElem''@ if it exhausts all other options.
type family IsElem endpoint api :: Constraint where
    IsElem e (sa :<|> sb)                   = Or (IsElem e sa) (IsElem e sb)
    IsElem (e :> sa) (e :> sb)              = IsElem sa sb
    IsElem sa (Header sym x :> sb)          = IsElem sa sb
    IsElem sa (ReqBody y x :> sb)           = IsElem sa sb
    IsElem (CaptureAll z y :> sa) (CaptureAll x y :> sb)
                                            = IsElem sa sb
    IsElem (Capture z y :> sa) (Capture x y :> sb)
                                            = IsElem sa sb
    IsElem sa (QueryParam x y :> sb)        = IsElem sa sb
    IsElem sa (QueryParams x y :> sb)       = IsElem sa sb
    IsElem sa (QueryFlag x :> sb)           = IsElem sa sb
    IsElem (Verb m s ct typ) (Verb m s ct' typ)
                                            = IsSubList ct ct'
    IsElem e e                              = ()
    IsElem e a                              = IsElem' e a

-- | Check whether @sub@ is a sub API of @api@.
type family IsSubAPI sub api :: Constraint where
  IsSubAPI sub api = AllIsElem (Endpoints sub) api

-- | Check that every element of @xs@ is an endpoint of @api@ (using @'IsElem'@).
type family AllIsElem xs api :: Constraint where
  AllIsElem '[] api = ()
  AllIsElem (x ': xs) api = (IsElem x api, AllIsElem xs api)

-- ** Strict inclusion

-- | Closed type family, check if @endpoint@ is exactly within @api@.
-- We aren't sure what affects how an endpoint is built up, so we require an
-- exact match.
type family IsIn (endpoint :: *) (api :: *) :: Constraint where
    IsIn e (sa :<|> sb)                = Or (IsIn e sa) (IsIn e sb)
    IsIn (e :> sa) (e :> sb)           = IsIn sa sb
    IsIn e e                           = ()

-- | Check whether @sub@ is a sub API of @api@.
type family IsStrictSubAPI sub api :: Constraint where
  IsStrictSubAPI sub api = AllIsIn (Endpoints sub) api

-- | Check that every element of @xs@ is an endpoint of @api@ (using @'IsIn'@).
type family AllIsIn xs api :: Constraint where
  AllIsIn '[] api = ()
  AllIsIn (x ': xs) api = (IsIn x api, AllIsIn xs api)

-- * Helpers

-- ** Lists

-- | Apply @(e :>)@ to every API in @xs@.
type family MapSub e xs where
  MapSub e '[] = '[]
  MapSub e (x ': xs) = (e :> x) ': MapSub e xs

-- | Append two type-level lists.
type family AppendList xs ys where
  AppendList '[]       ys = ys
  AppendList (x ': xs) ys = x ': AppendList xs ys

type family IsSubList a b :: Constraint where
    IsSubList '[] b          = ()
    IsSubList (x ': xs) y    = Elem x y `And` IsSubList xs y

#if !MIN_VERSION_base(4,9,0)
-- | Check that a value is an element of a list:
--
-- >>> ok (Proxy :: Proxy (Elem Bool '[Int, Bool]))
-- OK
--
-- >>> ok (Proxy  :: Proxy (Elem String '[Int, Bool]))
-- ...
--     No instance for (ElemNotFoundIn [Char] '[Int, Bool])
--       arising from a use of ‘ok’
-- ...
type Elem e es = ElemGo e es es
#else
-- | Check that a value is an element of a list:
--
-- >>> ok (Proxy :: Proxy (Elem Bool '[Int, Bool]))
-- OK
--
-- >>> ok (Proxy  :: Proxy (Elem String '[Int, Bool]))
-- ...
-- ... [Char] expected in list '[Int, Bool]
-- ...
type Elem e es = ElemGo e es es
#endif

-- 'orig' is used to store original list for better error messages
type family ElemGo e es orig :: Constraint where
    ElemGo x (x ': xs) orig = ()
    ElemGo y (x ': xs) orig = ElemGo y xs orig
#if MIN_VERSION_base(4,9,0)
    -- Note [Custom Errors]
    ElemGo x '[] orig       = TypeError ('ShowType x
                                    ':<>: 'Text " expected in list "
                                    ':<>: 'ShowType orig)
#else
    ElemGo x '[] orig       = ElemNotFoundIn x orig
#endif

-- ** Logic

-- | If either a or b produce an empty constraint, produce an empty constraint.
type family Or (a :: Constraint) (b :: Constraint) :: Constraint where
    -- This works because of:
    -- https://ghc.haskell.org/trac/ghc/wiki/NewAxioms/CoincidentOverlap
    Or () b       = ()
    Or a ()       = ()

-- | If both a or b produce an empty constraint, produce an empty constraint.
type family And (a :: Constraint) (b :: Constraint) :: Constraint where
    And () ()     = ()

-- * Custom type errors

#if !MIN_VERSION_base(4,9,0)
class ElemNotFoundIn val list
#endif

{- Note [Custom Errors]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
We might try to factor these our more cleanly, but the type synonyms and type
families are not evaluated (see https://ghc.haskell.org/trac/ghc/ticket/12048).
-}

-- $setup
-- >>> import Data.Proxy
-- >>> data OK = OK deriving (Show)
-- >>> let ok :: ctx => Proxy ctx -> OK; ok _ = OK
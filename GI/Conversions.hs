{-# LANGUAGE PatternGuards, DeriveFunctor, OverloadedStrings #-}

module GI.Conversions
    ( convert
    , genConversion
    , unpackCArray
    , computeArrayLength

    , hToF
    , fToH
    , haskellType
    , foreignType

    , argumentType
    , elementType
    , elementMap
    , elementTypeAndMap

    , isManaged
    , isNullable

    , getIsScalar
    , requiresAlloc

    , apply
    , mapC
    , literal
    , Constructor(..)
    ) where

import Control.Applicative ((<$>))
import Control.Monad (when)
import Control.Monad.Free (Free(..), liftF)
import Data.Typeable (TypeRep, tyConName, typeRepTyCon, typeOf)
import GHC.Exts (IsString(..))
import Data.Int
import Data.Word

import GI.API
import GI.Code
import GI.GObject
import GI.SymbolNaming
import GI.Type
import GI.Util

import GI.Internal.ArgInfo (Transfer(..))

-- String identifying a constructor in the generated code, which is
-- either (by default) a pure function (indicated by the P
-- constructor) or a function returning values on a monad (M
-- constructor). 'Id' denotes the identity function.
data Constructor = P String | M String | Id
                   deriving (Eq,Show)
instance IsString Constructor where
    fromString cs = P cs

data FExpr next = Apply Constructor next
                | MapC Constructor next
                | Literal Constructor next
                  deriving (Show, Functor)

type Converter = Free FExpr ()

apply :: Constructor -> Converter
apply f = liftF $ Apply f ()

mapC :: Constructor -> Converter
mapC f = liftF $ MapC f ()

literal :: Constructor -> Converter
literal f = liftF $ Literal f ()

genConversion :: String -> Converter -> CodeGen String
genConversion l (Pure ()) = return l
genConversion l (Free k) = do
  let l' = prime l
  case k of
    Apply (P f) next ->
        do line $ "let " ++ l' ++ " = " ++ f ++ " " ++ l
           genConversion l' next
    Apply (M f) next ->
        do line $ l' ++ " <- " ++ f ++ " " ++ l
           genConversion l' next
    Apply Id next -> genConversion l next

    MapC (P f) next ->
        do line $ "let " ++ l' ++ " = map " ++ f ++ " " ++ l
           genConversion l' next
    MapC (M f) next ->
        do line $ l' ++ " <- mapM " ++ f ++ " " ++ l
           genConversion l' next
    MapC Id next -> genConversion l next

    Literal (P f) next ->
        do line $ "let " ++ l ++ " = " ++ f
           genConversion l next
    Literal (M f) next ->
        do line $ l ++ " <- " ++ f
           genConversion l next
    Literal Id next -> genConversion l next

-- Given an array, together with its type, return the code for reading
-- its length.
computeArrayLength :: String -> Type -> ExcCodeGen String
computeArrayLength array (TCArray _ _ _ t) = do
  reader <- findReader
  return $ "fromIntegral $ " ++ reader ++ " " ++ array
    where findReader = case t of
                     TBasicType TUInt8 -> return "B.length"
                     TBasicType _ -> return "length"
                     TInterface _ _ -> return "length"
                     TCArray _ _ _ _ -> return "length"
                     _ -> notImplementedError $
                          "Don't know how to compute length of "
                          ++ show t
computeArrayLength _ t =
    notImplementedError $ "computeArrayLength called on non-CArray type "
                            ++ show t

convert :: String -> BaseCodeGen e Converter -> BaseCodeGen e String
convert l c = do
  c' <- c
  genConversion l c'

hObjectToF :: Type -> Transfer -> ExcCodeGen Constructor
hObjectToF t transfer = do
  if transfer == TransferEverything
  then do
    isGO <- isGObject t
    if isGO
    then return $ M "refObject"
    else badIntroError "Transferring a non-GObject object"
  else return "unsafeManagedPtrGetPtr"

hVariantToF :: Transfer -> CodeGen Constructor
hVariantToF transfer = do
  if transfer == TransferEverything
  then return $ M "refGVariant"
  else return "unsafeManagedPtrGetPtr"

hParamSpecToF :: Transfer -> CodeGen Constructor
hParamSpecToF transfer = do
  if transfer == TransferEverything
  then return $ M "refGParamSpec"
  else return "unsafeManagedPtrGetPtr"

hBoxedToF :: Transfer -> CodeGen Constructor
hBoxedToF transfer = do
  if transfer == TransferEverything
  then return $ M "copyBoxed"
  else return "unsafeManagedPtrGetPtr"

hStructToF :: Struct -> Transfer -> ExcCodeGen Constructor
hStructToF s transfer =
    if transfer /= TransferEverything || structIsBoxed s then
        hBoxedToF transfer
    else do
        when (structSize s == 0) $
             badIntroError "Transferring a non-boxed struct with unknown size!"
        return "unsafeManagedPtrGetPtr"

hUnionToF :: Union -> Transfer -> ExcCodeGen Constructor
hUnionToF u transfer =
    if transfer /= TransferEverything || unionIsBoxed u then
        hBoxedToF transfer
    else do
        when (unionSize u == 0) $
             badIntroError "Transferring a non-boxed union with unknown size!"
        return "unsafeManagedPtrGetPtr"

-- Given the Haskell and Foreign types, returns the name of the
-- function marshalling between both.
hToF' :: Type -> Maybe API -> TypeRep -> TypeRep -> Transfer
            -> ExcCodeGen Constructor
hToF' t a hType fType transfer
    | ( hType == fType ) = return Id
    | TError <- t = hBoxedToF transfer
    | TVariant <- t = hVariantToF transfer
    | TParamSpec <- t = hParamSpecToF transfer
    | Just (APIEnum _) <- a = return "(fromIntegral . fromEnum)"
    | Just (APIFlags _) <- a = return "gflagsToWord"
    | Just (APIObject _) <- a = hObjectToF t transfer
    | Just (APIInterface _) <- a = hObjectToF t transfer
    | Just (APIStruct s) <- a = hStructToF s transfer
    | Just (APIUnion u) <- a = hUnionToF u transfer
    -- Converting callback types requires more context, we leave that
    -- as a special case to be implemented by the caller.
    | Just (APICallback _) <- a = error "Cannot handle callback type here!! "
    | TByteArray <- t = return $ M "packGByteArray"
    | TCArray True _ _ (TBasicType TUTF8) <- t =
        return $ M "packZeroTerminatedUTF8CArray"
    | TCArray True _ _ (TBasicType TFileName) <- t =
        return $ M "packZeroTerminatedFileNameArray"
    | TCArray True _ _ (TBasicType TVoid) <- t =
        return $ M "packZeroTerminatedPtrArray"
    | TCArray True _ _ (TBasicType TUInt8) <- t =
        return $ M "packZeroTerminatedByteString"
    | TCArray True _ _ (TBasicType TBoolean) <- t =
        return $ M "(packMapZeroTerminatedStorableArray (fromIntegral . fromEnum))"
    | TCArray True _ _ (TBasicType TGType) <- t =
        return $ M "(packMapZeroTerminatedStorableArray gtypeToCGtype)"
    | TCArray True _ _ (TBasicType _) <- t =
        return $ M "packZeroTerminatedStorableArray"
    | TCArray False _ _ (TBasicType TUTF8) <- t =
        return $ M "packUTF8CArray"
    | TCArray False _ _ (TBasicType TFileName) <- t =
        return $ M "packFileNameArray"
    | TCArray False _ _ (TBasicType TVoid) <- t =
        return $ M "packPtrArray"
    | TCArray False _ _ (TBasicType TUInt8) <- t =
        return $ M "packByteString"
    | TCArray False _ _ (TBasicType TBoolean) <- t =
        return $ M "(packMapStorableArray (fromIntegral . fromEnum))"
    | TCArray False _ _ (TBasicType TGType) <- t =
        return $ M "(packMapStorableArray gtypeToCGType)"
    | TCArray False _ _ (TBasicType TFloat) <- t =
        return $ M "(packMapStorableArray realToFrac)"
    | TCArray False _ _ (TBasicType TDouble) <- t =
        return $ M "(packMapStorableArray realToFrac)"
    | TCArray False _ _ (TBasicType _) <- t =
        return $ M "packStorableArray"
    | TCArray _ _ _ _ <- t = notImplementedError
                         $ "Don't know how to pack C array of type " ++ show t
    | TGHash _ _ <- t = notImplementedError
                    "Hash tables are not properly supported yet"
    | otherwise = case (show hType, show fType) of
               ("T.Text", "CString") -> return $ M "textToCString"
               ("[Char]", "CString") -> return $ M "stringToCString"
               ("Char", "CInt")      -> return "(fromIntegral . ord)"
               ("Bool", "CInt")      -> return "(fromIntegral . fromEnum)"
               ("Float", "CFloat")   -> return "realToFrac"
               ("Double", "CDouble") -> return "realToFrac"
               ("GType", "CGType")   -> return "gtypeToCGType"
               _                     ->
                   notImplementedError $ "Don't know how to convert "
                                           ++ show hType ++ " into "
                                           ++ show fType ++ ".\n"
                                           ++ "Internal type: "
                                           ++ show t

hToF_PackedType t packer transfer = do
  a <- findAPI t
  hType <- haskellType t
  fType <- foreignType t
  innerConstructor <- hToF' t a hType fType transfer
  return $ do
    mapC innerConstructor
    apply (M packer)

hToF :: Type -> Transfer -> ExcCodeGen Converter
hToF (TGList t) transfer = hToF_PackedType t "packGList" transfer
hToF (TGSList t) transfer = hToF_PackedType t "packGSList" transfer
hToF (TGArray t) transfer = hToF_PackedType t "packGArray" transfer
hToF (TPtrArray t) transfer = hToF_PackedType t "packGPtrArray" transfer
-- Arrays without length info are just passed along.
hToF (TCArray False (-1) (-1) _) _ = return $ Pure ()
hToF (TCArray zt _ _ t@(TCArray _ _ _ _)) transfer = do
  let packer = if zt
               then "packZeroTerminated"
               else "pack"
  hToF_PackedType t (packer ++ "PtrArray") transfer

hToF (TCArray zt _ _ t@(TInterface _ _)) transfer = do
  isScalar <- getIsScalar t
  let packer = if zt
               then "packZeroTerminated"
               else "pack"
  if isScalar
  then hToF_PackedType t (packer ++ "StorableArray") transfer
  else do
    api <- findAPI t
    let size = case api of
                 Just (APIStruct s) -> structSize s
                 Just (APIUnion u) -> unionSize u
                 _ -> 0
    if size == 0 || zt
    then hToF_PackedType t (packer ++ "PtrArray") transfer
    else hToF_PackedType t (packer ++ "BlockArray " ++ show size) transfer

hToF t transfer = do
  a <- findAPI t
  hType <- haskellType t
  fType <- foreignType t
  constructor <- hToF' t a hType fType transfer
  return $ apply constructor

boxedForeignPtr :: String -> Transfer -> CodeGen Constructor
boxedForeignPtr constructor transfer = return $
   case transfer of
     TransferEverything -> M $ parenthesize $ "wrapBoxed " ++ constructor
     _ -> M $ parenthesize $ "newBoxed " ++ constructor

suForeignPtr :: Bool -> Int -> TypeRep -> Transfer -> CodeGen Constructor
suForeignPtr isBoxed size hType transfer = do
  let constructor = tyConName $ typeRepTyCon hType
  if isBoxed then
      boxedForeignPtr constructor transfer
  else case size of
         0 -> do
           line "-- XXX Wrapping a foreign struct/union with no known destructor, leak?"
           return $ M $ parenthesize $
                      "\\x -> " ++ constructor ++ " <$> newForeignPtr_ x"
         n -> return $ M $ parenthesize $
              case transfer of
                TransferEverything -> "wrapPtr " ++ constructor
                _ -> "newPtr " ++ show n ++ " " ++ constructor

structForeignPtr :: Struct -> TypeRep -> Transfer -> CodeGen Constructor
structForeignPtr s hType transfer =
    suForeignPtr (structIsBoxed s) (structSize s) hType transfer

unionForeignPtr :: Union -> TypeRep -> Transfer -> CodeGen Constructor
unionForeignPtr u hType transfer =
    suForeignPtr (unionIsBoxed u) (unionSize u) hType transfer

fObjectToH :: Type -> TypeRep -> Transfer -> ExcCodeGen Constructor
fObjectToH t hType transfer = do
  let constructor = tyConName $ typeRepTyCon hType
  isGO <- isGObject t
  case transfer of
    TransferEverything ->
        if isGO
        then return $ M $ parenthesize $ "wrapObject " ++ constructor
        else badIntroError $ "Got a transfer of something not a GObject"
    _ ->
        if isGO
        then return $ M $ parenthesize $ "newObject " ++ constructor
        else badIntroError $ "Wrapping not a GObject with no copy..."

fCallbackToH :: Callback -> TypeRep -> Transfer -> ExcCodeGen Constructor
fCallbackToH _ _ _ =
  notImplementedError "Wrapping foreign callbacks is not supported yet"

fVariantToH :: Transfer -> CodeGen Constructor
fVariantToH transfer =
  return $ M $ case transfer of
                  TransferEverything -> "wrapGVariantPtr"
                  _ -> "newGVariantFromPtr"

fParamSpecToH :: Transfer -> CodeGen Constructor
fParamSpecToH transfer =
  return $ M $ case transfer of
                  TransferEverything -> "wrapGParamSpecPtr"
                  _ -> "newGParamSpecFromPtr"

fToH' :: Type -> Maybe API -> TypeRep -> TypeRep -> Transfer
         -> ExcCodeGen Constructor
fToH' t a hType fType transfer
    | ( hType == fType ) = return Id
    | Just (APIEnum _) <- a = return "(toEnum . fromIntegral)"
    | Just (APIFlags _) <- a = return "wordToGFlags"
    | TError <- t = boxedForeignPtr "GI.GLib.Error" transfer
    | TVariant <- t = fVariantToH transfer
    | TParamSpec <- t = fParamSpecToH transfer
    | Just (APIStruct s) <- a = structForeignPtr s hType transfer
    | Just (APIUnion u) <- a = unionForeignPtr u hType transfer
    | Just (APIObject _) <- a = fObjectToH t hType transfer
    | Just (APIInterface _) <- a = fObjectToH t hType transfer
    | Just (APICallback c) <- a = fCallbackToH c hType transfer
    | TCArray True _ _ (TBasicType TUTF8) <- t =
        return $ M "unpackZeroTerminatedUTF8CArray"
    | TCArray True _ _ (TBasicType TFileName) <- t =
        return $ M "unpackZeroTerminatedFileNameArray"
    | TCArray True _ _ (TBasicType TUInt8) <- t =
        return $ M "unpackZeroTerminatedByteString"
    | TCArray True _ _ (TBasicType TVoid) <- t =
        return $ M "unpackZeroTerminatedPtrArray"
    | TCArray True _ _ (TBasicType TBoolean) <- t =
        return $ M "(unpackMapZeroTerminatedStorableArray (/= 0))"
    | TCArray True _ _ (TBasicType TGType) <- t =
        return $ M "(unpackMapZeroTerminatedStorableArray GType)"
    | TCArray True _ _ (TBasicType TFloat) <- t =
        return $ M "(unpackMapZeroTerminatedStorableArray realToFrac)"
    | TCArray True _ _ (TBasicType TDouble) <- t =
        return $ M "(unpackMapZeroTerminatedStorableArray realToFrac)"
    | TCArray True _ _ (TBasicType _) <- t =
        return $ M "unpackZeroTerminatedStorableArray"
    | TCArray _ _ _ _ <- t =
      notImplementedError $ "Don't know how to unpack C array of type " ++ show t
    | TByteArray <- t = return $ M "unpackGByteArray"
    | TGHash _ _ <- t = notImplementedError "Foreign Hashes not supported yet"
    | otherwise = case (show fType, show hType) of
               ("CString", "T.Text") -> return $ M "cstringToText"
               ("CString", "[Char]") -> return $ M "cstringToString"
               ("CInt", "Char")      -> return "(chr . fromIntegral)"
               ("CInt", "Bool")      -> return "(/= 0)"
               ("CFloat", "Float")   -> return "realToFrac"
               ("CDouble", "Double") -> return "realToFrac"
               ("CGType", "GType")   -> return "GType"
               _                     ->
                   notImplementedError $ "Don't know how to convert "
                                           ++ show fType ++ " into "
                                           ++ show hType ++ ".\n"
                                           ++ "Internal type: "
                                           ++ show t

fToH_PackedType t unpacker transfer = do
  a <- findAPI t
  hType <- haskellType t
  fType <- foreignType t
  innerConstructor <- fToH' t a hType fType transfer
  return $ do
    apply (M unpacker)
    mapC innerConstructor

fToH :: Type -> Transfer -> ExcCodeGen Converter

fToH (TGList t) transfer = fToH_PackedType t "unpackGList" transfer
fToH (TGSList t) transfer = fToH_PackedType t "unpackGSList" transfer
fToH (TGArray t) transfer = fToH_PackedType t "unpackGArray" transfer
fToH (TPtrArray t) transfer = fToH_PackedType t "unpackGPtrArray" transfer
-- Arrays without length info are just passed along.
fToH (TCArray False (-1) (-1) _) _ = return $ Pure ()
fToH (TCArray True _ _ t@(TCArray _ _ _ _)) transfer =
  fToH_PackedType t "unpackZeroTerminatedPtrArray" transfer
fToH (TCArray True _ _ t@(TInterface _ _)) transfer = do
  isScalar <- getIsScalar t
  if isScalar
  then fToH_PackedType t "unpackZeroTerminatedStorableArray" transfer
  else fToH_PackedType t "unpackZeroTerminatedPtrArray" transfer

fToH t transfer = do
  a <- findAPI t
  hType <- haskellType t
  fType <- foreignType t
  constructor <- fToH' t a hType fType transfer
  return $ apply constructor

unpackCArray :: String -> Type -> Transfer -> ExcCodeGen Converter
unpackCArray length (TCArray False _ _ t) transfer =
  case t of
    TBasicType TUTF8 -> return $ apply $ M $ parenthesize $
                        "unpackUTF8CArrayWithLength " ++ length
    TBasicType TFileName -> return $ apply $ M $ parenthesize $
                            "unpackFileNameArrayWithLength " ++ length
    TBasicType TUInt8 -> return $ apply $ M $ parenthesize $
                         "unpackByteStringWithLength " ++ length
    TBasicType TVoid -> return $ apply $ M $ parenthesize $
                         "unpackPtrArrayWithLength " ++ length
    TBasicType TBoolean -> return $ apply $ M $ parenthesize $
                         "unpackMapStorableArrayWithLength (/= 0) " ++ length
    TBasicType TGType -> return $ apply $ M $ parenthesize $
                         "unpackMapStorableArrayWithLength GType " ++ length
    TBasicType TFloat -> return $ apply $ M $ parenthesize $
                         "unpackMapStorableArrayWithLength realToFrac " ++ length
    TBasicType TDouble -> return $ apply $ M $ parenthesize $
                         "unpackMapStorableArrayWithLength realToFrac " ++ length
    TBasicType _ -> return $ apply $ M $ parenthesize $
                         "unpackStorableArrayWithLength " ++ length
    TInterface _ _ -> do
           a <- findAPI t
           isScalar <- getIsScalar t
           hType <- haskellType t
           fType <- foreignType t
           innerConstructor <- fToH' t a hType fType transfer
           let (boxed, size) = case a of
                        Just (APIStruct s) -> (structIsBoxed s, structSize s)
                        Just (APIUnion u) -> (unionIsBoxed u, unionSize u)
                        _ -> (False, 0)
           let unpacker = if isScalar
                          then "unpackStorableArrayWithLength"
                          else if size == 0
                               then "unpackPtrArrayWithLength"
                               else if boxed
                                    then "unpackBoxedArrayWithLength " ++ show size
                                    else "unpackBlockArrayWithLength " ++ show size
           return $ do
             apply $ M $ parenthesize $ unpacker ++ " " ++ length
             mapC innerConstructor
    _ -> notImplementedError $
         "unpackCArray : Don't know how to unpack C Array of type " ++ show t

unpackCArray _ _ _ =
    notImplementedError $ "unpackCArray : unexpected array type."

-- Given a type find the typeclasses the type belongs to, and return
-- the representation of the type in the function signature and the
-- list of typeclass constraints for the type.
argumentType :: [Char] -> Type -> CodeGen ([Char], String, [String])
argumentType [] _               = error "out of letters"
argumentType letters (TGList a) = do
  (ls, name, constraints) <- argumentType letters a
  return (ls, "[" ++ name ++ "]", constraints)
argumentType letters (TGSList a) = do
  (ls, name, constraints) <- argumentType letters a
  return (ls, "[" ++ name ++ "]", constraints)
argumentType letters@(l:ls) t   = do
  api <- findAPI t
  s <- show <$> haskellType t
  case api of
    Just (APIInterface _) -> do
             isGO <- isGObject t
             let constraints =
                     if isGO
                     then [goConstraint s ++ " " ++ [l]]
                     else [interfaceClassName s ++ " " ++ [l],
                           "ManagedPtr " ++ [l]]
             return (ls, [l], constraints)
    -- Instead of restricting to the actual class,
    -- we allow for any object descending from it.
    Just (APIObject _) -> do
        isGO <- isGObject t
        if isGO
        then return (ls, [l], [goConstraint s ++ " " ++ [l]])
        else return (letters, s, [])
    _ -> return (letters, s, [])

haskellBasicType TVoid     = (ptr (typeOf ()))
haskellBasicType TBoolean  = typeOf True
haskellBasicType TInt8     = typeOf (0 :: Int8)
haskellBasicType TUInt8    = typeOf (0 :: Word8)
haskellBasicType TInt16    = typeOf (0 :: Int16)
haskellBasicType TUInt16   = typeOf (0 :: Word16)
haskellBasicType TInt32    = typeOf (0 :: Int32)
haskellBasicType TUInt32   = typeOf (0 :: Word32)
haskellBasicType TInt64    = typeOf (0 :: Int64)
haskellBasicType TUInt64   = typeOf (0 :: Word64)
haskellBasicType TGType    = "GType" `con` []
haskellBasicType TUTF8     = "T.Text" `con` []
haskellBasicType TFloat    = typeOf (0 :: Float)
haskellBasicType TDouble   = typeOf (0 :: Double)
haskellBasicType TUniChar  = typeOf ('\0' :: Char)
haskellBasicType TFileName = "[Char]" `con` []

-- This translates GI types to the types used for generated Haskell code.
haskellType :: Type -> CodeGen TypeRep
haskellType (TBasicType bt) = return $ haskellBasicType bt
-- We cannot really do anything sensible for a foreign array with no
-- length info, so just pass the pointer along.
haskellType (TCArray False (-1) (-1) t) =
    ptr <$> foreignType t
haskellType (TCArray _ _ _ (TBasicType TUInt8)) =
    return $ "ByteString" `con` []
haskellType (TCArray _ _ _ a) = do
  inner <- haskellType a
  return $ "[]" `con` [inner]
haskellType (TGArray a) = do
  inner <- haskellType a
  return $ "[]" `con` [inner]
haskellType (TPtrArray a) = do
  inner <- haskellType a
  return $ "[]" `con` [inner]
haskellType (TByteArray) = return $ "ByteString" `con` []
haskellType (TGList a) = do
  inner <- haskellType a
  return $ "[]" `con` [inner]
haskellType (TGSList a) = do
  inner <- haskellType a
  return $ "[]" `con` [inner]
haskellType (TGHash a b) = do
  innerA <- haskellType a
  innerB <- haskellType b
  return $ "GHashTable" `con` [innerA, innerB]
haskellType TError = return $ "Error" `con` []
haskellType TVariant = return $ "GVariant" `con` []
haskellType TParamSpec = return $ "GParamSpec" `con` []
haskellType (TInterface "GObject" "Value") = return $ "GValue" `con` []
haskellType (TInterface "GObject" "Closure") = return $ "Closure" `con` []
haskellType t@(TInterface ns n) = do
  prefix <- qualify ns
  api <- findAPI t
  let tname = (prefix ++ n) `con` []
  return $ case api of
             Just (APIFlags _) -> "[]" `con` [tname]
             _ -> tname

foreignBasicType TVoid     = ptr (typeOf ())
foreignBasicType TBoolean  = "CInt" `con` []
foreignBasicType TUTF8     = "CString" `con` []
foreignBasicType TFileName = "CString" `con` []
foreignBasicType TUniChar  = "CInt" `con` []
foreignBasicType TFloat    = "CFloat" `con` []
foreignBasicType TDouble   = "CDouble" `con` []
foreignBasicType TGType    = "CGType" `con` []
foreignBasicType t         = haskellBasicType t

-- This translates GI types to the types used in foreign function calls.
foreignType :: Type -> CodeGen TypeRep
foreignType (TBasicType t) = return $ foreignBasicType t
foreignType (TCArray False (-1) (-1) t) =
    ptr <$> foreignType t
foreignType (TCArray zt _ _ t) = do
  api <- findAPI t
  let size = case api of
               Just (APIStruct s) -> structSize s
               Just (APIUnion u) -> unionSize u
               _ -> 0
  if size == 0 || zt
  then ptr <$> foreignType t
  else foreignType t
foreignType (TGArray a) = do
  inner <- foreignType a
  return $ ptr ("GArray" `con` [inner])
foreignType (TPtrArray a) = do
  inner <- foreignType a
  return $ ptr ("GPtrArray" `con` [inner])
foreignType (TByteArray) = return $ ptr ("GByteArray" `con` [])
foreignType (TGList a) = do
  inner <- foreignType a
  return $ ptr ("GList" `con` [inner])
foreignType (TGSList a) = do
  inner <- foreignType a
  return $ ptr ("GSList" `con` [inner])
foreignType t@(TGHash _ _) = ptr <$> haskellType t
foreignType t@TError = ptr <$> haskellType t
foreignType t@TVariant = ptr <$> haskellType t
foreignType t@TParamSpec = ptr <$> haskellType t
foreignType (TInterface "GObject" "Value") = return $ ptr $ "GValue" `con` []
foreignType (TInterface "GObject" "Closure") =
    return $ ptr $ "Closure" `con` []
foreignType t@(TInterface ns n) = do
  isScalar <- getIsScalar t
  if isScalar
  then return $ "CUInt" `con` []
  else do
    api <- findAPI t
    prefix <- qualify ns
    return $ case api of
               Just (APICallback _) -> ("FunPtr " ++ prefix ++ n ++ "C")
                                       `con` []
               _ -> ptr $ (prefix ++ n) `con` []

getIsScalar :: Type -> CodeGen Bool
getIsScalar t = do
  a <- findAPI t
  case a of
    Nothing -> return False
    (Just (APIEnum _)) -> return True
    (Just (APIFlags _)) -> return True
    _ -> return False

-- Whether the given type corresponds to a struct we allocate
-- ourselves. If we need to allocate the struct we return its size in
-- bytes and whether the type is boxed, otherwise we return Nothing.
requiresAlloc :: Type -> CodeGen (Maybe (Bool, Int))
requiresAlloc t = do
  api <- findAPI t
  case api of
    Just (APIStruct s) -> case structSize s of
                            0 -> return Nothing
                            n -> return (Just (structIsBoxed s, n))
    _ -> return Nothing

-- Returns whether the given type corresponds to a ManagedPtr
-- instance (a thin wrapper over a ForeignPtr).
isManaged   :: Type -> CodeGen Bool
isManaged t = do
  a <- findAPI t
  case a of
    Just (APIObject _)    -> return True
    Just (APIInterface _) -> return True
    Just (APIStruct _)    -> return True
    Just (APIUnion _)     -> return True
    _                     -> return False

-- Returns whether the given type is nullable in the C sense,
-- i.e. whether it can be set to NULL.
isNullable :: Type -> Bool
isNullable (TBasicType TVoid) = True
isNullable (TBasicType TUTF8) = True
isNullable (TBasicType TFileName) = True
isNullable (TBasicType _) = False
isNullable _ = True

-- If the given type maps to a list in Haskell, return the type of the
-- elements, and the function that maps over them.
elementTypeAndMap :: Type -> String -> Maybe (Type, String)
-- Passed along as a raw pointer.
elementTypeAndMap (TCArray False (-1) (-1) _) _ = Nothing
-- ByteString
elementTypeAndMap (TCArray _ _ _ (TBasicType TUInt8)) _ = Nothing
elementTypeAndMap (TCArray True _ _ t) _ = Just (t, "mapZeroTerminatedCArray")
elementTypeAndMap (TCArray False (-1) _ t) len =
    Just (t, parenthesize $ "mapCArrayWithLength " ++ len)
elementTypeAndMap (TCArray False fixed _ t) _ =
    Just (t, parenthesize $ "mapCArrayWithLength " ++ show fixed)
elementTypeAndMap (TGArray t) _ = Just (t, "mapGArray")
elementTypeAndMap (TPtrArray t) _ = Just (t, "mapPtrArray")
elementTypeAndMap (TGList t) _ = Just (t, "mapGList")
elementTypeAndMap (TGSList t) _ = Just (t, "mapGSList")
elementTypeAndMap _ _ = Nothing

-- Return just the element type.
elementType :: Type -> Maybe Type
elementType t = fst <$> elementTypeAndMap t undefined

-- Return just the map.
elementMap :: Type -> String -> Maybe String
elementMap t len = snd <$> elementTypeAndMap t len

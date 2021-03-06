{-# Language ScopedTypeVariables #-}
-- | Patches.
module Csound.Air.Patch(
  
	CsdNote, Instr, Fx, Fx1, Fx2, FxSpec(..), DryWetRatio,
	Patch1, Patch2, Patch(..), PolySyntSpec(..), MonoSyntSpec(..),
    polySynt, monoSynt,

    mapPatchInstr, mapMonoPolyInstr, transPatch, dryPatch, getPatchFx,	
    setFxMix, setFxMixes,
    setMidiChn,

	-- * Midi
	atMidi, 

	-- * Events
	atSched,
	atSchedUntil,

	-- * Sco
	atSco,

	-- * Single note
	atNote,

	-- * Fx
    addInstrFx, addPreFx, addPostFx,

	-- * Pads
	harmonPatch, deepPad,

	-- * Misc
	patchWhen, 

    mixInstr,

	-- * Rever
	withSmallRoom, withSmallRoom', 
	withSmallHall, withSmallHall',
	withLargeHall, withLargeHall',
	withMagicCave, withMagicCave',

	-- * Sound font patches
	sfPatch, sfPatchHall,

    -- * Monosynt params
    onMonoSyntSpec, setMonoSharp, setMonoHold,
	
    -- * Csound API
    patchByNameMidi,

	-- * Custom temperament
	-- ** Midi
	atMidiTemp,
	-- ** Csound API
    patchByNameMidiTemp	    
) where

import Data.Boolean
import Data.Default    
import Control.Monad
import Control.Applicative
import Control.Arrow(second)

import Csound.Typed
import Csound.SigSpace
import Csound.Control.Midi
import Csound.Control.Instr
import Csound.Control.Sf
import Csound.Air.Fx
import Csound.Typed.Opcode(cpsmidinn, ampdb)
import Csound.Tuning
import Csound.Types

-- | A simple csound note (good for playing with midi-keyboard).
-- It's a pair of amplitude (0 to 1) and freuqncy (Hz).
type CsdNote a = (a, a)

-- | An instrument transforms a note to a signal.
type Instr a b = CsdNote a -> SE b

-- | An effect processes the input signal.
type Fx a = a  -> SE a
type DryWetRatio = Sig

-- | Mono effect.
type Fx1 = Fx Sig

-- | Stereo effect.
type Fx2 = Fx Sig2

-- | Fx specification. It;s a pair of dryWet ratio and a transformation function.
data FxSpec a = FxSpec
	{ fxMix :: DryWetRatio
	, fxFun :: Fx a	
	}

-- | Mono-output patch.
type Patch1 = Patch Sig

-- | Stereo-output patch.
type Patch2 = Patch Sig2

-- | Specification for monophonic synthesizer.
-- 
-- * Chn -- midi channel to listen on
--
-- * Hold -- to hold the note or not
--
-- * SlideTime -- time of transition between notes
--
-- * SyntRelease -- time of release
data MonoSyntSpec = MonoSyntSpec
    { monoSyntChn       :: MidiChn  
    , monoSyntHold      :: Bool
    , monoSyntSlideTime :: D
    , monoSyntRelease   :: D }

instance Default MonoSyntSpec where
    def = MonoSyntSpec 
        { monoSyntChn = ChnAll
        , monoSyntHold = False
        , monoSyntSlideTime = 0.01
        , monoSyntRelease = 0.1 }

data PolySyntSpec = PolySyntSpec
    { polySyntChn :: MidiChn }

instance Default PolySyntSpec where
    def = PolySyntSpec { polySyntChn = ChnAll }

-- | The patch can be:
--
-- *  a plain monophonic or polyphonic synthesizer
--
-- * patch with chain of effects, 
--
-- * split on keyboard with certain frequency
--
-- * layer of patches. That is a several patches that sound at the same time.
--  the layer is a patch and the weight of volume for a given patch.
data Patch a 
    = MonoSynt MonoSyntSpec (Instr Sig a)
    | PolySynt PolySyntSpec (Instr D   a)
    | FxChain [FxSpec a] (Patch a)
    | SplitPatch (Patch a) D (Patch a)
    | LayerPatch [(Sig, Patch a)]


polySynt :: (Instr D a) -> Patch a
polySynt = PolySynt def

monoSynt :: (Instr Sig a) -> Patch a
monoSynt = MonoSynt def

-- Maps all monophonic and polyphonic patches within the given patch.
mapMonoPolyInstr :: (Instr Sig a -> Instr Sig a) -> (Instr D a -> Instr D a) -> Patch a -> Patch a
mapMonoPolyInstr mono poly x = case x of
    MonoSynt spec instr -> MonoSynt spec (mono instr)
    PolySynt spec instr -> PolySynt spec (poly instr)
    FxChain  fxs p      -> FxChain fxs (rec p)
    LayerPatch xs       -> LayerPatch (mapSnd rec xs)
    SplitPatch a dt b   -> SplitPatch (rec a) dt (rec b)
    where
        rec = mapMonoPolyInstr mono poly

-- Maps all polyphonic patches within the given patch.
mapPatchInstr :: (Instr D a -> Instr D a) -> Patch a -> Patch a
mapPatchInstr f x = case x of
    MonoSynt _ _ -> x
    PolySynt spec instr -> PolySynt spec $ f instr
    FxChain fxs p -> FxChain fxs $ rec p
    LayerPatch xs -> LayerPatch (mapSnd rec xs)
    SplitPatch a dt b -> SplitPatch (rec a) dt (rec b)
    where
        rec = mapPatchInstr f

-- | Removes all effects from the patch.
dryPatch :: Patch a -> Patch a
dryPatch x = case x of
    MonoSynt spec instr -> x
    PolySynt spec instr -> x
    FxChain _ p         -> dryPatch p
    SplitPatch a dt b   -> SplitPatch (dryPatch a) dt (dryPatch b)
    LayerPatch xs       -> LayerPatch $ mapSnd dryPatch xs

-- | Sets the dryWet ratio of the effects wwithin the patch.
setFxMix :: Sig -> Patch a -> Patch a
setFxMix a = setFxMixes [a]

-- | Sets the dryWet ratios for the chain of the effects wwithin the patch.
setFxMixes :: [Sig] -> Patch a -> Patch a
setFxMixes ks p = case p of
    FxChain fxs x -> FxChain (zipFirst (\k x -> x { fxMix = k }) ks fxs) x
    _ -> p
    where
        zipFirst f xs ys = case (xs, ys) of
            (_,    [])   -> []
            ([],   bs)   -> bs
            (a:as, b:bs) -> f a b : zipFirst f as bs

--------------------------------------------------------------

instance SigSpace a => SigSpace (Patch a) where
	mapSig f x = 
            case x of
                MonoSynt spec instr -> MonoSynt spec $ fmap (mapSig f) . instr
                PolySynt spec instr -> PolySynt spec $ fmap (mapSig f) . instr
                FxChain fxs p  -> FxChain fxs $ mapSig f p
                SplitPatch a dt b -> SplitPatch (mapSig f a) dt (mapSig f b)
                LayerPatch xs  -> FxChain [FxSpec 1 (return . mapSig f)] $ LayerPatch xs

mapSnd :: (a -> b) -> [(c, a)] -> [(c, b)]
mapSnd f = fmap (second f) 

wet :: (SigSpace a, Sigs a) => FxSpec a -> Fx a
wet (FxSpec k fx) asig = fmap ((mul (1 - k) asig + ) . mul k) $ fx asig

-- | Renders the effect chain to a single function.
getPatchFx :: (SigSpace a, Sigs a) => [FxSpec a] -> Fx a
getPatchFx xs = foldr (<=<) return $ fmap wet xs

-- | Plays a patch with a single infinite note.
atNote :: (SigSpace a, Sigs a) => Patch a -> CsdNote D -> SE a
atNote p note@(amp, cps) = case p of
    MonoSynt spec instr -> instr (sig amp, sig cps)
    PolySynt spec instr -> instr note
    FxChain fxs p -> getPatchFx fxs =<< rec p
    LayerPatch xs -> onLayered xs rec
    SplitPatch a t b -> getSplit (cps `lessThan` t) (rec a) (rec b)
    where
        rec x = atNote x note

getSplit :: (Num a, Tuple a) => BoolD -> SE a -> SE a -> SE a
getSplit cond a b = do
    ref <- newRef 0
    whenElseD cond 
        (mixRef ref =<< a)
        (mixRef ref =<< b)
    readRef ref

--------------------------------------------------------------
-- midi

midiChn :: Sigs a => MidiChn -> (Msg -> SE a) -> SE a
midiChn chn = case chn of
    ChnAll -> midi
    Chn n  -> midin n
    Pgm pgm chn -> pgmidi pgm chn

-- | Plays a patch with midi. 
atMidi :: (SigSpace a, Sigs a) => Patch a -> SE a
atMidi x = case x of
    MonoSynt spec instr -> monoSynt spec instr
    PolySynt spec instr -> midiChn (polySyntChn spec) (instr . ampCps)
    FxChain fxs p -> getPatchFx fxs =<< atMidi p
    LayerPatch xs -> onLayered xs atMidi
    SplitPatch a dt b -> genMidiSplitPatch ampCps a dt b
    where
        monoSynt spec instr = instr =<< getArg
            where
                getArg
                    | monoSyntHold spec = holdMsg chn port
                    | otherwise         = monoMsg chn port rel

                port = monoSyntSlideTime spec
                rel  = monoSyntRelease spec
                chn  = monoSyntChn spec

-- | Plays a patch with midi with given temperament (see @Csound.Tuning@).
atMidiTemp :: (SigSpace a, Sigs a) => Temp -> Patch a -> SE a
atMidiTemp tm x = case x of
    MonoSynt spec instr -> monoSynt spec instr
    PolySynt spec instr -> midiChn (polySyntChn spec) (instr . ampCps' tm)
    FxChain fxs p -> getPatchFx fxs =<< atMidiTemp tm p
    LayerPatch xs -> onLayered xs (atMidiTemp tm)
    SplitPatch a cps b -> genMidiSplitPatch (ampCps' tm) a cps b
    where
        monoSynt spec instr = instr =<< getArg
            where
                getArg
                    | monoSyntHold spec = holdMsgTemp tm chn port
                    | otherwise         = monoMsgTemp tm chn port rel

                port = monoSyntSlideTime spec
                rel  = monoSyntRelease spec
                chn  = monoSyntChn spec

genMidiSplitPatch :: (SigSpace a, Sigs a) => (Msg -> (D, D)) -> Patch a -> D -> Patch a -> SE a
genMidiSplitPatch midiArg = genSplitPatch $ \chn instr -> midiChn chn (instr . midiArg)

genSplitPatch :: (SigSpace a, Sigs a) => (MidiChn -> (CsdNote D -> SE a) -> SE a) -> Patch a -> D -> Patch a -> SE a
genSplitPatch playInstr a dt b = liftA2 (+) (leftSplit dt a) (rightSplit dt b)
    where
        leftSplit  dt a = onCondPlay ( `lessThan` dt) a
        rightSplit dt a = onCondPlay ( `greaterThanEquals` dt) a

        onCondPlay cond x = case x of
            MonoSynt spec instr -> error "Split doesn't work for monophonic synths. Pleas use only polyphonic synths."
            PolySynt spec instr -> playInstr (polySyntChn spec) (restrictPolyInstr cond instr)
            FxChain fxs p -> getPatchFx fxs =<< onCondPlay cond p
            LayerPatch xs -> onLayered xs (onCondPlay cond)
            SplitPatch a dt b -> liftA2 (+) 
                        (onCondPlay (\x -> cond x &&* (x `lessThan` dt)) a) 
                        (onCondPlay (\x -> cond x &&* (x `greaterThanEquals` dt)) b)

restrictPolyInstr :: (Sigs a) => (D -> BoolD) -> (CsdNote D -> SE a) -> CsdNote D -> SE a
restrictPolyInstr cond instr note@(amp, cps) = do
    ref <- newRef 0
    whenElseD (cond cps) 
        (writeRef ref =<< instr note)
        (writeRef ref 0)
    readRef ref

--------------------------------------------------------------
-- sched

-- | Plays a patch with event stream. 
atSched :: (SigSpace a, Sigs a) => Patch a -> Evt (Sco (CsdNote D)) -> SE a
atSched x evt = case x of
    MonoSynt _ instr -> error "atSched is not defined for monophonic synthesizers"
    PolySynt _ instr -> playInstr instr
    FxChain fxs p  -> getPatchFx fxs =<< atSched p evt
    LayerPatch xs -> onLayered xs (\patch -> atSched patch evt)
    SplitPatch a t b -> genSplitPatch (const playInstr) a t b
    where playInstr instr = return $ sched instr evt


-- | Plays a patch with event stream with stop-note event stream. 
atSchedUntil :: (SigSpace a, Sigs a) => Patch a -> Evt (CsdNote D) -> Evt b -> SE a
atSchedUntil x evt stop = case x of     
    MonoSynt _ instr -> error "atSchedUntil is not defined for monophonic synthesizers"
    PolySynt _ instr -> playInstr instr
    FxChain fxs p  -> getPatchFx fxs =<< atSchedUntil p evt stop
    LayerPatch xs -> onLayered xs (\patch -> atSchedUntil patch evt stop)
    SplitPatch a cps b -> genSplitPatch (const playInstr) a cps b
    where playInstr instr = return $ schedUntil instr evt stop

--------------------------------------------------------------
-- sco
 
-- | Plays a patch with scores. 
atSco :: (SigSpace a, Sigs a) => Patch a -> Sco (CsdNote D) -> Sco (Mix a)
atSco x sc = case x of
    MonoSynt _ instr -> error "atSco is not defined for monophonic synthesizers"
    PolySynt _ instr -> sco instr sc 
    FxChain fxs p  -> eff (getPatchFx fxs) $atSco p sc
    LayerPatch xs -> har $ fmap (\(vol, p) -> atSco (mul vol p) sc) xs
    SplitPatch a cps b -> undefined    
--    eff (getPatchFx p) $ sco (patchInstr p) sc 

scoSplitPatch :: (SigSpace a, Sigs a) => Patch a -> D -> Patch a -> Sco (CsdNote D) -> Sco (Mix a)
scoSplitPatch a dt b sc = har [leftSplit dt a, rightSplit dt b]
    where
        leftSplit  dt a = onCondPlay ( `lessThan` dt) a
        rightSplit dt a = onCondPlay ( `greaterThanEquals` dt) a

        onCondPlay cond x = case x of
            MonoSynt spec instr -> error "Split doesn't work for monophonic synths. Pleas use only polyphonic synths."
            PolySynt spec instr -> sco (restrictPolyInstr cond instr) sc
            FxChain fxs p -> eff (getPatchFx fxs) $ atSco p sc
            LayerPatch xs -> har $ fmap (\(vol, p) -> atSco (mul vol p) sc) xs
            SplitPatch a dt b -> har 
                        [ onCondPlay (\x -> cond x &&* (x `lessThan` dt)) a
                        , onCondPlay (\x -> cond x &&* (x `greaterThanEquals` dt)) b ]

onLayered :: (SigSpace a, Sigs a) => [(Sig, Patch a)] -> (Patch a -> SE a) -> SE a
onLayered xs f = fmap sum $ mapM (\(vol, p) -> fmap (mul vol) $ f p) xs

--    getPatchFx a =<< midi (patchInstr a . ampCps)    

-- | Transform  the spec for monophonic patch.
onMonoSyntSpec :: (MonoSyntSpec -> MonoSyntSpec) -> Patch a -> Patch a
onMonoSyntSpec f x = case x of
    MonoSynt spec instr -> MonoSynt (f spec) instr
    PolySynt spec instr -> PolySynt spec instr
    FxChain fxs p -> FxChain fxs $ onMonoSyntSpec f p 
    LayerPatch xs -> LayerPatch $ mapSnd (onMonoSyntSpec f) xs
    SplitPatch a cps b -> SplitPatch (onMonoSyntSpec f a) cps (onMonoSyntSpec f b)

-- | Sets the midi channel for all instruments in the patch.
setMidiChn :: MidiChn -> Patch a -> Patch a
setMidiChn chn x = case x of
    MonoSynt spec instr -> MonoSynt (spec { monoSyntChn = chn }) instr
    PolySynt spec instr -> PolySynt (spec { polySyntChn = chn }) instr
    FxChain fxs p -> FxChain fxs $ go p 
    LayerPatch xs -> LayerPatch $ mapSnd go xs
    SplitPatch a cps b -> SplitPatch (go a) cps (go b)
    where go = setMidiChn chn


-- | Sets the monophonic to sharp transition and quick release.
setMonoSharp :: Patch a -> Patch a
setMonoSharp = onMonoSyntSpec (\x -> x { monoSyntSlideTime = 0.005, monoSyntRelease = 0.05 })

-- | Sets the monophonic patch to hold mode. All notes are held.
setMonoHold :: Patch a -> Patch a
setMonoHold = onMonoSyntSpec (\x -> x { monoSyntHold = True })

-- | Transpose the patch by a given ratio. We can use the functions semitone, cent to calculate the ratio.
transPatch :: D -> Patch a -> Patch a
transPatch k = mapMonoPolyInstr (\instr -> instr . second ( * sig k)) (\instr -> instr . second ( * k))

-- | Adds an effect to the patch's instrument.
addInstrFx :: Fx a -> Patch a -> Patch a
addInstrFx f p = mapPatchInstr (\instr -> f <=< instr) p

-- | Appends an effect before patch's effect.
addPreFx :: DryWetRatio -> Fx a -> Patch a -> Patch a
addPreFx dw f p = case p of
    FxChain fxs (PolySynt spec instr) -> FxChain (addFx fxs) (PolySynt spec instr)
    FxChain fxs (MonoSynt spec instr) -> FxChain (addFx fxs) (MonoSynt spec instr)
    PolySynt spec instr -> FxChain fxSpec $ PolySynt spec instr
    MonoSynt spec instr -> FxChain fxSpec $ MonoSynt spec instr
    LayerPatch xs -> LayerPatch $ mapSnd (addPreFx dw f) xs
    SplitPatch a cps b -> SplitPatch (addPreFx dw f a) cps (addPreFx dw f b)
    where 
        addFx xs = xs ++ fxSpec
        fxSpec = [FxSpec dw f]

-- | Appends an effect after patch's effect.
addPostFx :: DryWetRatio -> Fx a -> Patch a -> Patch a
addPostFx dw f p = case p of
    FxChain fxs rest -> FxChain (fxSpec : fxs) rest
    _                -> FxChain [fxSpec] p
    where fxSpec = FxSpec dw f

--------------------------------------------------------------

-- | Plays a patch when the condition signal is satisfied. Can be useful for switches.
patchWhen :: (Sigs a) => BoolSig -> Patch a -> Patch a
patchWhen cond x = case x of
    MonoSynt spec instr -> MonoSynt spec (playWhen cond instr)
    PolySynt spec instr -> PolySynt spec (playWhen cond instr)
    FxChain  fxs p      -> FxChain (fmap (mapFun (playWhen cond)) fxs) (rec p)
    LayerPatch xs       -> LayerPatch $ mapSnd rec xs
    SplitPatch a cps b  -> SplitPatch (rec a) cps (rec b)        
    where 
        rec = patchWhen cond
        mapFun f x = x { fxFun = f $ fxFun x }

-- | Mix two patches together.
mixInstr :: (SigSpace b, Num b) => Sig -> Patch b -> Patch b -> Patch b
mixInstr k f p = LayerPatch [(k, f), (1, p)]

------------------------------------------------
-- pads

-- | Harmnoic series of patches.
harmonPatch :: (SigSpace b, Sigs b) => [Sig] -> [D] -> Patch b -> Patch b
harmonPatch amps freqs = tfmInstr monoTfm polyTfm
    where
        monoTfm instr = \(amp, cps) -> fmap sum $ zipWithM (\a f -> fmap (mul a) $ instr (amp, cps * f)) amps (fmap sig freqs)
        polyTfm instr = \(amp, cps) -> fmap sum $ zipWithM (\a f -> fmap (mul a) $ instr (amp, cps * f)) amps freqs 

-- | Adds an octave below note for a given patch to make the sound deeper.
deepPad :: (SigSpace b, Sigs b) => Patch b -> Patch b
deepPad = harmonPatch (fmap (* 0.75) [1, 0.5]) [1, 0.5]

-- | Transforms instrument functions for polyphonic and monophonic patches.
tfmInstr :: ((CsdNote Sig -> SE b) -> (CsdNote Sig -> SE b)) -> ((CsdNote D -> SE b) -> (CsdNote D -> SE b)) -> Patch b -> Patch b
tfmInstr monoTfm polyTfm x = case x of
    MonoSynt spec instr -> MonoSynt spec $ monoTfm instr
    PolySynt spec instr -> PolySynt spec $ polyTfm instr
    FxChain fxs p -> FxChain fxs $ rec p
    SplitPatch a cps b -> SplitPatch (rec a) cps (rec b)
    LayerPatch xs -> LayerPatch $ mapSnd rec xs
    where
        rec = tfmInstr monoTfm polyTfm
        mapSnd f = fmap (second f) 

------------------------------------------------
-- revers

withSmallRoom :: Patch2 -> Patch2
withSmallRoom = withSmallRoom' 0.25

withSmallRoom' :: DryWetRatio -> Patch2 -> Patch2
withSmallRoom' = withRever smallRoom2

withSmallHall :: Patch2 -> Patch2
withSmallHall = withSmallHall' 0.25

withSmallHall' :: DryWetRatio -> Patch2 -> Patch2
withSmallHall' = withRever smallHall2

withLargeHall :: Patch2 -> Patch2
withLargeHall = withLargeHall' 0.25

withLargeHall' :: DryWetRatio -> Patch2 -> Patch2
withLargeHall' = withRever largeHall2

withMagicCave :: Patch2 -> Patch2
withMagicCave = withMagicCave' 0.25

withMagicCave' :: DryWetRatio -> Patch2 -> Patch2
withMagicCave' = withRever magicCave2

withRever :: (Sig2 -> Sig2) -> DryWetRatio -> Patch2 -> Patch2
withRever fx ratio p = addPostFx ratio (return . fx) p

------------------------------------------------
-- sound font patch

-- | Sound font patch with a bit of reverb.
sfPatchHall :: Sf -> Patch2
sfPatchHall = withSmallHall . sfPatch

-- | Sound font patch.
sfPatch :: Sf -> Patch2
sfPatch sf = PolySynt def $ \(amp, cps) -> return $ sfCps sf 0.5 amp cps

------------------------------------------------
-- Csound API


-- | Triggers patch with Csound API.
-- It creates a named instruement with given name (first argument).
--
-- It simulates the midi-like instrument. Notes are encoded with messages:
--
-- > i "givenName" 1 pitchKey volumeKey     -- note on
-- > i "givenName" 0 pitchKey volumeKey     -- note off
patchByNameMidi :: (SigSpace a, Sigs a) => String -> Patch a -> SE a
patchByNameMidi = genPatchByNameMidi cpsmidinn cpsmidinn

-- | Triggers patch with Csound API.
-- It creates a named instruement with given name (second argument).
-- It behaves like the function @patchByNameMidi@ but we can specify custom temperament.
patchByNameMidiTemp :: (SigSpace a, Sigs a) => Temp -> String -> Patch a -> SE a
patchByNameMidiTemp tm = genPatchByNameMidi (cpsmidi'Sig tm) (cpsmidi'D tm)

genPatchByNameMidi :: forall a . (SigSpace a, Sigs a) => (Sig -> Sig) -> (D -> D) -> String -> Patch a -> SE a
genPatchByNameMidi monoKey2cps polyKey2cps name x = case x of 
    MonoSynt spec instr -> monoSynt spec instr
    PolySynt spec instr -> polySynt spec instr
    FxChain fxs p       -> getPatchFx fxs =<< rec p
    LayerPatch xs       -> onLayered xs rec
    SplitPatch a cps b  -> splitPatch a cps b
    where
        rec = genPatchByNameMidi monoKey2cps polyKey2cps name

        monoSynt spec instr = instr =<< fmap convert (trigNamedMono portTime relTime name)
            where
                convert (vol, pch) = (vel2ampSig vol, monoKey2cps pch)
                portTime = monoSyntSlideTime spec
                relTime  = monoSyntRelease    spec

        polySynt spec instr = trigByNameMidi name go
            where
                go :: (D, D, Unit) -> SE a
                go (pitch, vol, _) = instr (vel2amp vol, polyKey2cps pitch)

        splitPatch a cps b = genSplitPatch polySynt a cps b

vel2amp :: D -> D
vel2amp vol = ((vol / 64) ** 2) / 2

vel2ampSig :: Sig -> Sig
vel2ampSig vol = ((vol / 64) ** 2) / 2

{-

-- | Triggers patch with Csound API.
-- It creates a named instruement with given name (first argument).
--
-- It simulates the midi-like instrument. Notes are encoded with messages:
--
-- > i "givenName" 1 pitchKey volumeKey     -- note on
-- > i "givenName" 0 pitchKey volumeKey     -- note off
patchByNameMidi :: (SigSpace a, Sigs a) => String -> Patch D a -> SE a
patchByNameMidi = genPatchByNameMidi cpsmidinn

-- | Triggers patch with Csound API.
-- It creates a named instruement with given name (second argument).
-- It behaves like the function @patchByNameMidi@ but we can specify custom temperament.
patchByNameMidiTemp :: (SigSpace a, Sigs a) => Temp -> String -> Patch D a -> SE a
patchByNameMidiTemp tm = genPatchByNameMidi (cpsmidi'D tm)

-- | Wrapper for function @trigByNameMidi@.
genPatchByNameMidi :: forall a . (SigSpace a, Sigs a) => (D -> D) -> String -> Patch D a -> SE a
genPatchByNameMidi key2cps name p = getPatchFx p =<< trigByNameMidi name go
	where
		go :: (D, D, Unit) -> SE a
		go (pitch, vol, _) = patchInstr p (vel2amp vol, key2cps pitch)


-- | Triggers patch with Csound API.
-- It creates a named instruement with given name (first argument).
--
-- It simulates the midi-like instrument. Notes are encoded with messages:
--
-- > i "givenName" 1 pitchKey volumeKey     -- note on
-- > i "givenName" 0 pitchKey volumeKey     -- note off
--
-- It behaves just like the function @patchByNameMidi@ but it's defined for
-- monophonic patches. For instruments that take in continuous signals not messages/notes.
monoPatchByNameMidi :: (SigSpace a, Sigs a) => String -> Patch Sig a -> SE a
monoPatchByNameMidi name p = monoPatchByNameMidi' 0.01 0.1 name p

-- | Triggers patch with Csound API.
-- It creates a named instruement with given name (first argument).
-- It behaves like the function @monoPatchByNameMidi@ but we can specify custom temperament.
monoPatchByNameMidiTemp :: (SigSpace a, Sigs a) => Temp -> String -> Patch Sig a -> SE a
monoPatchByNameMidiTemp tm name p = monoPatchByNameMidiTemp' tm 0.01 0.1 name p

-- | The monophonic patch with sharper transition from note to note.
monoSharpPatchByNameMidi :: (SigSpace a, Sigs a) => String -> Patch Sig a -> SE a
monoSharpPatchByNameMidi name p = monoPatchByNameMidi' 0.005 0.05 name p

-- | The monophonic patch with sharper transition from note to note.
-- We can specify a custom temperament.
monoSharpPatchByNameMidiTemp :: (SigSpace a, Sigs a) => Temp -> String -> Patch Sig a -> SE a
monoSharpPatchByNameMidiTemp tm name p = monoPatchByNameMidiTemp' tm 0.005 0.05 name p

-- | Generic function fr invocation of monophonic instrument with Csound API.
-- We can specify portamento and release times.
monoPatchByNameMidi' :: (SigSpace a, Sigs a) => D -> D -> String -> Patch Sig a -> SE a
monoPatchByNameMidi' = genMonoPatchByNameMidi' cpsmidinn

-- | Generic function fr invocation of monophonic instrument with Csound API.
-- We can specify portamento and release times. Also we can specify a temperament.
monoPatchByNameMidiTemp' :: (SigSpace a, Sigs a) => Temp -> D -> D -> String -> Patch Sig a -> SE a
monoPatchByNameMidiTemp' tm = genMonoPatchByNameMidi' (cpsmidi'Sig tm)

-- | Wrapper for function @trigByNameMidi@ for mono synth.
genMonoPatchByNameMidi' :: forall a . (SigSpace a, Sigs a) => (Sig -> Sig) -> D -> D -> String -> Patch Sig a -> SE a
genMonoPatchByNameMidi' key2cps portTime relTime name p = getPatchFx p =<< patchInstr p =<< fmap convert (trigNamedMono portTime relTime name)
	where
		convert (vol, pch) = (vel2ampSig vol, key2cps pch)

vel2amp :: D -> D
vel2amp vol = ((vol / 64) ** 2) / 2

vel2ampSig :: Sig -> Sig
vel2ampSig vol = ((vol / 64) ** 2) / 2

-}
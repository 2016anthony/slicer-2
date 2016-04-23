module Main where

import Data.Char (toUpper, toLower, isSpace)
import Data.List (nub, sortBy, find, delete)
import Data.Maybe (fromJust)

----------------------------------------------------------
------------ Overhead (data structures, etc.) ------------
----------------------------------------------------------

-- A Point data structure
data Point a = Point { x :: a, y :: a, z :: a } deriving Eq

instance Functor Point where
    fmap f (Point x y z) = Point (f x) (f y) (f z)

-- Display a Point in the format expected by G-code
-- TODO: Will we have too many decimal places when trying to do this with Doubles?
-- Data.Scientific might be useful, but trying to deal with that case will probably
-- break this---and redefining Point to essentially be a Point Double will break the
-- Functor instance.
instance (Show a) => Show (Point a) where
    show p = unwords $ zipWith (++) ["X","Y","Z"] (map show [x p, y p, z p])

-- Data structure for a line segment in the form (x,y,z) = (x0,y0,z0) + t(mx,my,mz)
-- t should run from 0 to 1, so the endpoints are (x0,y0,z0) and (x0 + mx, y0 + my, z0 + mz)
-- TODO: Is this the best representation, or does it make sense to just have a line
-- defined by its endpoints? It feels like doing that may make some computations more
-- complex than they need to be.
data Line a = Line { point :: Point a, slope :: Point a } deriving Eq

data Facet a = Facet { sides :: [Line a] } deriving Eq

-- This should correspond to one line of G-code
type Command = [String]

-- Given a command, write it as one line of G-code
showCommand :: Command -> String
showCommand = map toUpper . unwords

-- Add the coordinates of two points
addPoints :: Num a => Point a -> Point a -> Point a
addPoints (Point x1 y1 z1) (Point x2 y2 z2) = Point (x1 + x2) (y1 + y2) (z1 + z2)

-- Scale the coordinates of a point by s
scalePoint :: Num a => a -> Point a -> Point a
scalePoint = fmap . (*)

-- Distance between two points
distance :: (Floating a, RealFrac a, Num a) => Point a -> Point a -> a
distance (Point x1 y1 z1) (Point x2 y2 z2) = sqrt $ (x1 - x2)^2 + (y1 - y2)^2 + (z1 - z2)^2

-- Create a line given its endpoints
lineFromEndpoints :: Num a => Point a -> Point a -> Line a
lineFromEndpoints p1 p2 = Line p1 (addPoints (scalePoint (-1) p1) p2)

-- Get the other endpoint
endpoint :: Num a => Line a -> Point a
endpoint l = addPoints (point l) (slope l)

-- Find the point on a line for a given Z value. Note that this evaluates to Nothing
-- in the case that there is no point with that Z value, or if that is the only
-- Z value present in that line. The latter should be okay because the properties
-- of our meshes mean that the two endpoints of our line should be captured by
-- the other two segments of a triangle.
pointAtZValue :: (Num a, RealFrac a) => Line a -> a -> Maybe (Point a)
pointAtZValue (Line p m) v
    | 0 <= t && t <= 1 = Just $ addPoints p (scalePoint t m)
    | otherwise = Nothing
    where t = (v - z p) / z m

----------------------------------------------------------
----------- Functions to deal with STL parsing -----------
----------------------------------------------------------

-- Separate lines of STL file into facets
facetsFromSTL :: [String] -> [[String]]
facetsFromSTL [] = []
facetsFromSTL [a] = []
facetsFromSTL l = map (map (dropWhile isSpace)) $ f : facetsFromSTL (tail r)
    where (f, r) = break (\s -> filter (not . isSpace) (map toLower s) == "endfacet") l

-- Clean up a list of strings from STL file (corresponding to a facet) into just
-- the vertices
cleanupFacet :: [String] -> [String]
cleanupFacet = map unwords . map tail . filter ((== "vertex") . head) . map words

-- Read a point when it's given a string of the form "x y z"
readPoint :: Read a => String -> Point a
readPoint s = Point a b c
    where [a,b,c] = map read $ take 3 $ words s 

-- Given a list of points (in order), construct lines that go between them. Note
-- that this is NOT cyclic, which is why we make sure we have cyclicity in readFacet
makeLines :: Num a => [Point a] -> [Line a]
makeLines l
    | length l < 2 = []
    | otherwise = lineFromEndpoints (head l) (head l') : makeLines l'
    where l' = tail l

-- Read a list of three coordinates (as strings separated by spaces) into the correct
-- Lines
readFacet :: (Num a, Read a) => [String] -> Facet a
readFacet f
    | length f < 3 = error "Invalid facet"
    | otherwise = Facet $ makeLines $ map readPoint f'
    where f' = last f : f -- So that we're cyclic

-- TODO: add header

-- From STL file (as a list of Strings, each String corresponding to one line),
-- produce a list of lists of Lines, where each list of Lines corresponds to a
-- facet in the original STL
facetLinesFromSTL :: (Num a, Read a) => [String] -> [Facet a]
facetLinesFromSTL = map readFacet . map cleanupFacet . facetsFromSTL

-- Determine if a triangle intersects a plane at a given z value
triangleIntersects :: (Eq a, RealFrac a) => a -> Facet a -> [Point a]
triangleIntersects v f = trimIntersections $ map fromJust $ filter (/= Nothing) intersections
    where intersections = map (flip pointAtZValue v) (sides f)

-- Get rid of the case where a triangle intersects the plane at one point
trimIntersections :: Eq a => [Point a] -> [Point a]
trimIntersections l
    | length l' <= 1 = []
    | otherwise = l'
    where l' = nub l

-- Find all the points in the mesh at a given z value
-- Each list in the output should have length 2, corresponding to a line segment
allIntersections :: (Eq a, RealFrac a) => a -> [Facet a] -> [[Point a]]
allIntersections v fs = filter (/= []) $ map (triangleIntersects v) fs

-- Turn pairs of points into lists of connected points
getContours :: (Eq a) => [[Point a]] -> [[Point a]]
getContours = makeContours . (,) []

-- From a list of contours we have already found and a list of pairs of points
-- (each corresponding to a segment), get all contours described by the points
makeContours :: (Eq a) => ([[Point a]], [[Point a]]) -> [[Point a]]
makeContours (contours, pairs)
    | pairs == [] = contours
    | otherwise = makeContours (contours ++ [next], ps)
    where (next, ps) = findContour (head pairs, tail pairs)

-- Extract a single contour from a list of points
findContour :: (Eq a) => ([Point a], [[Point a]]) -> ([Point a], [[Point a]])
findContour (contour, pairs)
    | p == Nothing = (contour, pairs)
    | otherwise = findContour (contour ++ (delete (last contour) p'), delete p' pairs)
    where match p0 = head p0 == last contour || last p0 == last contour
          p = find match pairs 
          p' = fromJust p 


-- Sort lists of point pairs by x-value of first point in the pair
sortSegments :: (Ord a) => [[Point a]] -> [[Point a]]
sortSegments = sortBy orderSegments 

orderSegments :: (Ord a) => [Point a] -> [Point a] -> Ordering
orderSegments (p1:_) (p2:_) 
    | x p1 == x p2 = compare (y p1) (y p2)
    | otherwise = compare (x p1) (x p2)

-- in mm
nozzleDiameter, filamentDiameter, layerHeight :: RealFrac a => a
nozzleDiameter = 0.4
filamentDiameter = 1.75
layerHeight = 0.2

-- Amount to extrude when making a line between two points
extrusionAmount :: (Floating a, Num a, RealFrac a) => Point a -> Point a -> a
extrusionAmount p1 p2 = nozzleDiameter * layerHeight * (2 / filamentDiameter) * l / pi
    where l = distance p1 p2

-- Given a contour and the point to start from, evaluate to the amount to extrude between
-- each move
extrusions :: (Floating a, Num a, RealFrac a) => Point a -> [Point a] -> [a]
extrusions _ [] = []
extrusions p c = extrusionAmount p (head c) : extrusions (head c) (tail c)

-- Take absolute values, turn into accumulated values
accumulateValues :: Num a => [a] -> [a]
accumulateValues [] = []
accumulateValues [a] = [a]
accumulateValues (a:b:cs) = a : accumulateValues (a + b : cs)

-- Generate G-code for a given contour
gcodeForContour :: (Show a, Floating a, Num a, RealFrac a) => [Point a] -> [String]
gcodeForContour c = map ((++) "G1 ") $ zipWith (++) (map show c) ("":es)
    where es = map ((++) " E") $ map show exVals
          exVals = accumulateValues $ extrusions (head c) (tail c)

main :: IO ()
main = do
    stl <- readFile "cube.stl"
    let stlLines = lines stl
    let facets = facetLinesFromSTL stlLines :: [Facet Double]
    let intersections = allIntersections 10 facets -- just a test, contour at z = 10
    let contours = getContours intersections
    let gcode = concatMap gcodeForContour contours
    writeFile "sampleGcode.txt" (unlines gcode)

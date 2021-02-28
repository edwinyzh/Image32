unit Image32_Transform;

(*******************************************************************************
* Author    :  Angus Johnson                                                   *
* Version   :  1.53                                                            *
* Date      :  22 October 2020                                                 *
* Website   :  http://www.angusj.com                                           *
* Copyright :  Angus Johnson 2019-2020                                         *
* Purpose   :  Affine and projective transformation routines for TImage32      *
* License   :  http://www.boost.org/LICENSE_1_0.txt                            *
*******************************************************************************)

interface

{$I Image32.inc}

uses
  SysUtils, Classes, Math, Types, Image32, Image32_Draw, Image32_Vector;

procedure AffineTransformImage(img: TImage32; matrix: TMatrixD); overload;
procedure AffineTransformImage(img: TImage32;
  matrix: TMatrixD; out offset: TPoint); overload;

//ProjectiveTransform:
//  srcPts, dstPts => each path must contain 4 points
//  margins => the margins around dstPts (in the dest. projective).
//  Margins are only meaningful when srcPts are inside the image.
function ProjectiveTransform(img: TImage32;
  const srcPts, dstPts: TPathD; const margins: TRect): Boolean;

function SplineVertTransform(img: TImage32; const topSpline: TPathD;
  splineType: TSplineType; backColor: TColor32; reverseFill: Boolean;
  out offset: TPoint): Boolean;
function SplineHorzTransform(img: TImage32; const leftSpline: TPathD;
  splineType: TSplineType; backColor: TColor32; reverseFill: Boolean;
  out offset: TPoint): Boolean;

implementation

//------------------------------------------------------------------------------
// Affine Transformation
//------------------------------------------------------------------------------

function GetTransformBounds(img: TImage32; const matrix: TMatrixD): TRect;
var
  pts: TPathD;
begin
  pts := Rectangle(img.Bounds);
  MatrixApply(matrix, pts);
  Result := GetBounds(pts);
end;
//------------------------------------------------------------------------------

procedure AffineTransformImage(img: TImage32; matrix: TMatrixD);
var
  dummy: TPoint;
begin
  AffineTransformImage(img, matrix, dummy);
end;
//------------------------------------------------------------------------------

procedure AffineTransformImage(img: TImage32;
  matrix: TMatrixD; out offset: TPoint); overload;
var
  i,j, w,h, dx,dy: integer;
  pt: TPointD;
  pc: PColor32;
  tmp: TArrayOfColor32;
  rec: TRect;
begin
  if img.Width * img.Height = 0 then Exit;
  rec := GetTransformBounds(img, matrix);
  offset := rec.TopLeft;

  dx := rec.Left; dy := rec.Top;
  w := RectWidth(rec); h := RectHeight(rec);

  //starting with the result pixel coords, reverse find
  //the fractional coordinates in the current image
  MatrixInvert(matrix);

  SetLength(tmp, w * h);
  pc := @tmp[0];
  for i := 0 to h -1 do
    for j := 0 to w -1 do
    begin
      pt.X := j + dx; pt.Y := i + dy;
      MatrixApply(matrix, pt);
      pc^ := GetWeightedPixel(img, Round(pt.X * 256), Round(pt.Y * 256));
      inc(pc);
    end;
  img.SetSize(w, h);
  Move(tmp[0], img.Pixels[0], w * h * sizeOf(TColor32));
end;

//------------------------------------------------------------------------------
// Projective Transformation
//------------------------------------------------------------------------------

procedure MatrixMulCoord(const matrix: TMatrixD; var x,y,z: double);
{$IFDEF INLINE} inline; {$ENDIF}
var
  xx, yy: double;
begin
  xx := x; yy := y;
  x := matrix[0,0] *xx + matrix[0,1] *yy + matrix[0,2] *z;
  y := matrix[1,0] *xx + matrix[1,1] *yy + matrix[1,2] *z;
  z := matrix[2,0] *xx + matrix[2,1] *yy + matrix[2,2] *z;
end;
//------------------------------------------------------------------------------

function BasisToPoints(x1, y1, x2, y2, x3, y3, x4, y4: double): TMatrixD;
var
  m, m2: TMatrixD;
  z4: double;
begin
  m := Matrix(x1, x2, x3, y1, y2, y3, 1,  1,  1);
  m2 := MatrixAdjugate(m);
  z4 := 1;
  MatrixMulCoord(m2, x4, y4, z4);
  m2 := Matrix(x4, 0, 0, 0, y4, 0, 0, 0, z4);
  Result := MatrixMultiply(m2, m);
end;
//------------------------------------------------------------------------------

procedure GetSrcCoords256(const matrix: TMatrixD; var x, y: integer);
{$IFDEF INLINE} inline; {$ENDIF}
var
  xx,yy,zz: double;
const
  Q: integer = MaxInt div 256;
begin
  //returns coords multiplied by 256 in anticipation of the following
  //GetWeightedPixel function call which in turn expects the lower 8bits
  //of the integer coord value to represent a fraction.
  xx := x; yy := y; zz := 1;
  MatrixMulCoord(matrix, xx, yy, zz);

  if zz = 0 then
  begin
    if xx >= 0 then x := Q else x := -MaxInt;
    if yy >= 0 then y := Q else y := -MaxInt;
  end else
  begin
    xx := xx/zz;
    if xx > Q then x := MaxInt
    else if xx < -Q then x := -MaxInt
    else x := Round(xx *256);

    yy := yy/zz;
    if yy > Q then y := MaxInt
    else if yy < -Q then y := -MaxInt
    else y := Round(yy *256);
  end;
end;
//------------------------------------------------------------------------------

function GetProjectionMatrix(const srcPts, dstPts: TPathD): TMatrixD;
var
  srcMat, dstMat: TMatrixD;
begin
  if (length(srcPts) <> 4) or (length(dstPts) <> 4) then
  begin
    Result := IdentityMatrix;
    Exit;
  end;
  srcMat := BasisToPoints(srcPts[0].X, srcPts[0].Y,
    srcPts[1].X, srcPts[1].Y, srcPts[2].X, srcPts[2].Y, srcPts[3].X, srcPts[3].Y);
  dstMat := BasisToPoints(dstPts[0].X, dstPts[0].Y,
    dstPts[1].X, dstPts[1].Y, dstPts[2].X, dstPts[2].Y, dstPts[3].X, dstPts[3].Y);
  Result := MatrixMultiply(MatrixAdjugate(dstMat), srcMat);
end;
//------------------------------------------------------------------------------

function ProjectiveTransform(img: TImage32;
  const srcPts, dstPts: TPathD; const margins: TRect): Boolean;
var
  w,h,i,j: integer;
  x,y: integer;
  rec: TRect;
  dstPts2: TPathD;
  mat: TMatrixD;
  tmp: TArrayOfColor32;
  pc: PColor32;
begin
  //https://math.stackexchange.com/a/339033/384709

  Result := not img.IsEmpty and
    (Length(dstPts) = 4) and IsPathConvex(dstPts);
  if not Result then Exit;

  rec := GetBounds(dstPts);
  dec(rec.Left, margins.Left);
  dec(rec.Top, margins.Top);
  inc(rec.Right, margins.Right);
  inc(rec.Bottom, margins.Bottom);
  dstPts2 := OffsetPath(dstPts, -rec.Left, -rec.Top);

  mat := GetProjectionMatrix(srcPts, dstPts2);
  w := RectWidth(rec);
  h := RectHeight(rec);
  SetLength(tmp, w * h);
  pc := @tmp[0];
  for i :=  0 to h -1 do
    for j := 0 to w -1 do
    begin
      x := j; y := i;
      GetSrcCoords256(mat, x, y);
      pc^ := GetWeightedPixel(img, x, y);
      inc(pc);
    end;
  img.SetSize(w, h);
  Move(tmp[0], img.Pixels[0], w * h * sizeOf(TColor32));
end;

//------------------------------------------------------------------------------
// Spline transformations
//------------------------------------------------------------------------------

function ReColor(color, newColor: TColor32): TColor32;
{$IFDEF INLINE} inline; {$ENDIF}
begin
  Result := Alpha(color) or NoAlpha(newColor);
end;
//------------------------------------------------------------------------------

function Interpolate(const pt1, pt2: TPointD; frac: double): TPointD;
begin
  if frac <= 0 then Result := pt1
  else if frac >= 1 then Result := pt2
  else
  begin
    result.X := pt1.X + frac * (pt2.X - pt1.X);
    result.Y := pt1.Y + frac * (pt2.Y - pt1.Y);
  end;
end;
//------------------------------------------------------------------------------

function InterpolateSegment(const pt1, pt2: TPointD): TPathD;
var
  i, len: integer;
  x,y,dx,dy: double;
begin
  len := Ceil(Distance(pt1, pt2));
  SetLength(Result, len);
  dy := (pt2.Y - pt1.Y)/ len;
  dx := (pt2.X - pt1.X)/ len;
  x := pt1.X; y := pt1.Y;
  for i := 0 to len -1 do
  begin
    x := x + dx; y := y + dy;
    Result[i] := PointD(x, y);
  end;
end;
//------------------------------------------------------------------------------

function InterpolatePath(const path: TPathD): TPathD;
var
  i,len,len2: integer;
  tmp: TPathD;
begin
  //returns a coordinate array for every value of X and y along the path based
  //on 2D distance. (This is a sadly only a poor approximation to perspective
  //distance - eg with tight bezier curves).
  len := length(path);
  setLength(result, 0);
  for i := 1 to len -1 do
  begin
    tmp := InterpolateSegment(path[i-1], path[i]);
    len := Length(Result);
    len2 := Length(tmp);
    SetLength(Result, len + len2);
    Move(tmp[0], Result[len], len2 * SizeOf(TPointD));
  end;
end;
//------------------------------------------------------------------------------

function SplineVertTransform(img: TImage32; const topSpline: TPathD;
  splineType: TSplineType; backColor: TColor32; reverseFill: Boolean;
  out offset: TPoint): Boolean;
var
  t,u,v, i,j, x,len, w,h: integer;
  prevX: integer;
  dx, dy, y, sy: double;
  topPath, botPath: TPathD;
  rec: TRect;
  scaleY: TArrayOfDouble;
  pc: PColor32;
  tmp: TArrayOfColor32;
  backColoring, allowBackColoring: Boolean;
begin
  offset := NullPoint;
  //convert the top spline control points into a flattened path
  if splineType = stQuadratic then
    topPath := FlattenQSpline(topSpline) else
    topPath := FlattenCSpline(topSpline);

  rec := GetBounds(topPath);
  //return false if the spline is invalid or there's no vertical transformation
  Result := not IsEmptyRect(rec);
  if not Result then Exit;

  offset := rec.TopLeft;
  topPath := OffsetPath(topPath, -rec.Left, -rec.Top);
  //'Interpolate' the path so that there's a coordinate for every rounded
  //X and Y between the start and end of the flattened spline path. This
  //is to give a very rough approximatation of distance, so that the image
  //is roughly proportionally spaced even when the spline causes overlap.
  topPath := InterpolatePath(topPath);
  botPath := OffsetPath(topPath, 0, img.Height);
  Image32_Vector.OffsetRect(rec, -rec.Left, -rec.Top);
  rec := Rect(UnionRect(RectD(rec), GetBoundsD(botPath)));
  w := RectWidth(rec); h := RectHeight(rec);
  len  := Length(topPath);

  setLength(scaleY, len);
  for i := 0 to len -1 do
    if botPath[i].Y <= topPath[i].Y then
      scaleY[i] := 0 else
      scaleY[i] := img.Height/ (botPath[i].Y - topPath[i].Y);

  dx := (img.Width / len) * 256;
  SetLength(tmp, w * h);

  if reverseFill then
  begin
    //ie fill from right-to-left or bottom-to-top
    t := -1; u := len -1; v := -1;
  end else
  begin
    t := 1; u := 0; v := len;
  end;
  prevX := u - t;

  backColoring := false;
  allowBackColoring := (backColor shr 24) > 2;
  while u <> v do
  begin
    //dst x:
    x := Round(topPath[u].X);
    if x >= w then begin inc(u, t); Continue; end;

    //check if reversing fill direction - ie folding overlap
    if allowBackColoring then
    begin
      if (x <> prevX) then
      begin
        if reverseFill then
          backColoring := prevX < x else
          backColoring := prevX > x;
      end
      else if (Abs(u -v) > 1) then //ie it's safe to look ahead
      begin
        if reverseFill then
          backColoring := prevX < topPath[u+t].X else
          backColoring := prevX > topPath[u+t].X;
      end;
    end;
    prevX := x;
    pc := @tmp[x];

    //src x:
    x := Round(u * dx);

    dy := topPath[u].Y;
    sy :=  scaleY[u];
    for j := 0 to h -1 do
    begin
      y := (j - dy) * sy;

      if backColoring then
        pc^ := BlendToAlpha(pc^,
          ReColor(GetWeightedPixel(img, x, Round(y * 256)), backColor))
      else
        //blend in case spline causes folding overlap
        pc^ := BlendToAlpha(pc^,
          GetWeightedPixel(img, x, Round(y * 256)));
      inc(pc, w);
    end;
    inc(u, t);
  end;
  img.SetSize(w, h);
  Move(tmp[0], img.PixelBase^, w * h * SizeOf(TColor32));
end;
//------------------------------------------------------------------------------

function SplineHorzTransform(img: TImage32; const leftSpline: TPathD;
  splineType: TSplineType; backColor: TColor32; reverseFill: Boolean;
  out offset: TPoint): Boolean;
var
  t,u,v, i,j, y,prevY, len, w,h: integer;
  x, dx,dy,sx: double;
  leftPath, rightPath: TPathD;
  rec: TRect;
  scaleX: TArrayOfDouble;
  pc: PColor32;
  tmp: TArrayOfColor32;
  backColoring, allowBackColoring: Boolean;
begin
  offset := NullPoint;

  //convert the left spline control points into a flattened path
  if splineType = stQuadratic then
    leftPath := FlattenQSpline(leftSpline) else
    leftPath := FlattenCSpline(leftSpline);
  rec := GetBounds(leftPath);
  //return false if the spline is invalid or there's no horizontal transformation
  Result := not IsEmptyRect(rec);
  if not Result then Exit;

  offset := rec.TopLeft;
  leftPath := OffsetPath(leftPath, -rec.Left, -rec.Top);
  //'Interpolate' the path so that there's a coordinate for every rounded
  //X and Y between the start and end of the flattened spline path. This
  //is to give a very rough approximatation of distance, so that the image
  //is roughly proportionally spaced even when the spline causes overlap.
  leftPath := InterpolatePath(leftPath);
  rightPath := OffsetPath(leftPath, img.Width, 0);
  Image32_Vector.OffsetRect(rec, -rec.Left, -rec.Top);
  rec := Rect(UnionRect(RectD(rec), GetBoundsD(rightPath)));
  w := RectWidth(rec); h := RectHeight(rec);
  len  := Length(leftPath);

  setLength(scaleX, len);
  for i := 0 to len -1 do
    if rightPath[i].X <= leftPath[i].X then
      scaleX[i] := 0 else
      scaleX[i] := img.Width / (rightPath[i].X - leftPath[i].X);

  dy := (img.Height / len) * 256;
  SetLength(tmp, w * h);

  if reverseFill then
  begin
    t := -1; u := len -1; v := -1;
  end else
  begin
    t := 1; u := 0; v := len;
  end;
  prevY := u - t;

  backColoring := false;
  allowBackColoring := (backColor shr 24) > 2;
  while u <> v do
  begin
    //dst y:
    y := Round(leftPath[u].Y);
    if y >= h then begin inc(u, t); Continue; end;

    //check if reversing fill direction - ie folding overlap
    if allowBackColoring then
    begin
      if (y <> prevY) then
      begin
        if reverseFill then
          backColoring := prevY < y else
          backColoring := prevY > y;
      end
      else if (Abs(u -v) > 1) then //ie it's safe to look ahead
      begin
        if reverseFill then
          backColoring := prevY < leftPath[u+t].Y else
          backColoring := prevY > leftPath[u+t].Y;
      end;
    end;

    prevY := y;
    pc := @tmp[y  * w];
    //src y:
    y := Round(u * dy);

    dx := leftPath[u].X;
    sx :=  scaleX[u];
    for j := 0 to w -1 do
    begin
      x := (j - dx) * sx;
      if backColoring then
        pc^ := BlendToAlpha(pc^,
          ReColor(GetWeightedPixel(img, Round(x * 256), y), backColor))
      else
        //blend in case spline causes folding overlap
        pc^ := BlendToAlpha(pc^, GetWeightedPixel(img, Round(x * 256), y));
      inc(pc);
    end;
    inc(u, t);
  end;
  img.SetSize(w, h);
  Move(tmp[0], img.PixelBase^, w * h * SizeOf(TColor32));
end;
//------------------------------------------------------------------------------

end.

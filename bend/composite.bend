import Base
import ./bendler.bend as B

def pair(x: U32 & String) -> U32 & String:
  x

def triple(x: U32 & String & Bool) -> U32 & String & Bool:
  x

def nested(x: (U32 & String) & List<Maybe<U32>>) -> (U32 & String) & List<Maybe<U32>>:
  x

def optional(x: Maybe<Maybe<U32>>) -> Maybe<Maybe<U32>>:
  x

def result(x: Result<(U32 & String), List<Maybe<U32>>>) -> Result<(U32 & String), List<Maybe<U32>>>:
  x

def blob(x: Maybe<Result<U32, (B.Bytes & Maybe<B.Bytes>)>>) -> Maybe<Result<U32, (B.Bytes & Maybe<B.Bytes>)>>:
  x

def empty(x: List<Maybe<Result<(U32 & String), List<U32>>>>) -> List<Maybe<Result<(U32 & String), List<U32>>>>:
  x

def right(x: U32 & (String & Bool)) -> U32 & (String & Bool):
  x

def wide(x: U32 & U32 & U32 & U32 & U32 & U32 & U32 & U32 & U32 & U32 & U32 & U32 & U32 & U32 & U32 & U32) -> U32 & U32 & U32 & U32 & U32 & U32 & U32 & U32 & U32 & U32 & U32 & U32 & U32 & U32 & U32 & U32:
  x

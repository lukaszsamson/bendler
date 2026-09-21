import Base

def pull.go(~ask: U32 -> IO(Maybe<U32>), fuel: Nat, +sum: U32, answer: Maybe<U32>) -> IO(U32):
  match fuel answer:
    case _ None{}:
      IO.pure(U32, sum)
    case 0n Some{x}:
      IO.pure(U32, U32.add(sum, x))
    case 1n+p Some{+x}:
      do IO<U32>:
        next : Maybe<U32> <- ask(U32.add(sum, x))
        pull.go(~ask, p, U32.add(sum, x), next)

def pull(~ask: U32 -> IO(Maybe<U32>), fuel: U32) -> IO(U32):
  pull.go(~ask, U32.to_nat(fuel), 0, Some{0})

def once(~ask: U32 -> IO(Maybe<U32>), x: U32) -> IO(Maybe<U32>):
  ask(x)

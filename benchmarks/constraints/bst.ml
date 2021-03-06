type 'a tree = Leaf of 'a | Node of 'a * 'a tree * 'a tree

let rec tree_min = function Leaf x -> x | Node (a, l, r) -> min a (min (tree_min l) (tree_min r))

let rec tree_max = function Leaf x -> x | Node (a, l, r) -> max a (min (tree_max l) (tree_max r))

let rec is_bst t = aux (tree_max t) (tree_min t) t

and aux hi lo = function
  | Leaf a -> lo <= a && a <= hi
  | Node (a, l, r) -> lo <= a && a <= hi && aux lo a l && aux a hi r

let repr x = x

let spec x t =
  let rec f = function
    | Leaf a -> if a < x then 1 else 0
    | Node (a, l, r) -> if a < x then 1 + f l + f r else f l + f r
  in
  f t
  [@@ensures fun x -> x >= 0]

let target y t =
  let rec g = function
    | Leaf a -> [%synt xi_0] y a
    | Node (a, l, r) -> if a < y then [%synt xi_1] (g l) (g r) else [%synt xi_2] (g l)
  in
  g t
  [@@requires is_bst]

---
title: Making Custom Datomic Datalog Datasources
subheadline: Data$ourcery!
categories: datasource datalog datomic-internals datomic
excerpt:
  Datomic's Datalog queries "datasources", which are usually a Datomic database.
  But the essence of a datasource is a pair of related protocols
  which return relations and perform joins and projection.
  You can use an ordinary collection as a datasource, or make your own!
---

## Disclaimers

What follows is not meant for those new to Datomic.
This is a _very_ deep dive into Datomic on-prem internals--even
deeper than usual!
I don't have access to any source code or any insider knowledge
and none of the interfaces discussed here are public,
so expect inaccuracies!

_Caveat Lector_ out of the way, let's get started.

<small>
(By the way, I no longer work at Shortcut and I am looking for a new role.
Perhaps you need someone who [knows Datomic][he-knows-datomic]?)
</small>

[he-knows-datomic]: https://clojurians.slack.com/archives/C02BJCKN0R4/p1691422594104289

## What are Datasources

Datomic datalog's `:where` clause has "[data-pattern]" sub-clauses.
For example:

[data-pattern]: https://docs.datomic.com/query/query-data-reference.html#data-patterns

```clojure
[:find ?foo
 :where
 [(+ 1 1) ?foo]         ;; This is a function-expression clause
 [?foo :attribute ?bar] ;; This is a data-pattern clause--the one we care about.
 [(< ?bar 1)]           ;; This is a predicate-expression clause
 ]
```

Data pattern clauses match tuples in a "datasource",
which we can also call a [relation].
Syntactically, datasources are datalog symbols that start with `$`.

[relation]: https://en.wikipedia.org/wiki/Relation_(database)

```clojure
[:find ?foo
 :in $ $h ;; two datasources $ and $h
 :where
 [?foo :attribute ?bar] ;; Implicitly datasource $
 [$h ?bar :other-attribute ?baz] ;; Explicitly datasource $h
 ]
```

Usually a datasource is a Datomic database,
but that's not the only thing it can be! 

My aim is to show you what "makes" a datasource,
so you can understand the performance of datalog queries better
and potentially make your own datasources.

(Spoiler alert: a datasource is a protocol.)

### The `ExtRel` Protocol

A datasource is anything that has a useful implementation of the 
`datomic.datalog/ExtRel` protocol.
(I'm not sure what this protocol name abbreviates.
Perhaps "existential relation"?)

```clojure
datomic.datalog/ExtRel
;; This is the map that defprotocol creates: 
=>
{:on datomic.datalog.ExtRel,
 :on-interface datomic.datalog.ExtRel,
 ;; Note the method signature
 :sigs {:extrel {:name extrel,
                 :arglists ([src consts starts whiles]),
                 :doc nil}},
 :var #'datomic.datalog/ExtRel,
 :method-map {:extrel :extrel},
 :method-builders {#'datomic.datalog/extrel #object[datomic.datalog$fn__17615 0x576cf258 "datomic.datalog$fn__17615@576cf258"]},
 ;; Note there are four implementations
 :impls {nil {:extrel #object[datomic.datalog$fn__17637 0x3c5ce098 "datomic.datalog$fn__17637@3c5ce098"]},
         java.lang.Object {:extrel #object[datomic.datalog$fn__17639 0x66250ab1 "datomic.datalog$fn__17639@66250ab1"]},
         datomic.db.Db {:extrel #object[datomic.datalog$fn__17641 0x2effa778 "datomic.datalog$fn__17641@2effa778"]},
         java.util.Map {:extrel #object[datomic.datalog$fn__17643 0x1e317ecd "datomic.datalog$fn__17643@1e317ecd"]},
         java.util.Collection {:extrel #object[datomic.datalog$fn__17645 0x45b215b3 "datomic.datalog$fn__17645@45b215b3"]}}}
```

From the protocol map we know that its definition
looked something like this:

```clojure
(defprotocol ExtRel
  (extrel [src consts starts whiles]))
```

And we know a few implementing objects to investigate.

## Built-in Datasources

### Collections

The `nil` and `Object` implementations are just to throw error messages:

```clojure
(d/q '[:find ?x ?y :in $ :where [?x ?y]]
     nil)
Execution error (Exceptions$IllegalArgumentExceptionInfo) at datomic.error/arg (error.clj:79).
:db.error/invalid-data-source Nil or missing data source. Did you forget to pass a database argument?
(d/q '[:find ?x ?y :in $ :where [?x ?y]]
     (Object.))
Execution error (Exceptions$IllegalArgumentExceptionInfo) at datomic.error/arg (error.clj:79).
:db.error/invalid-data-source class java.lang.Object is not a valid data source type.
```

Although `nil` and `Object` technically implement `ExtRel`,
these implementations are not "useful",
so I don't want to call these "datasources".

By contrast, `java.util.Collection` allows you to use any collection of tuples
as a datasource:

```clojure
;; Using a vector of tuples
(d/q '[:find ?e ?attr ?v
       :in $
       :where
       [(ground 1) ?e]
       [?e ?attr ?v]]
     [[1 :int 2] [1 :int 3] [2 :int 4]])
=> #{[1 :int 3] [1 :int 2]}
```

Note that this implementation has very few constraints:

* The outer collection can be anything that implements just `size` and 
  `iterator`. This includes Clojure's persistent vectors and sets.
* The tuples can be anything that supports indexed access via `nth`.
* Your tuples can be any length you want,
  but they should ideally be the *same* length to be a true relation.
  (Also you might get `IndexOutOfRange` exceptions.)

There's a special case for `java.util.Map` that just treats a map
as a collection of two-element tuples.
It seems to only need an `entrySet` method, and it probably just delegates 
the result to the `j.u.Collection` implementation.

### `ExtRel` Parameters

Let's instrument the `extrel` method to see what it calls.
This function will take a datasource and return a wrapped datasource with
a trace atom that records every call to its `extrel` method.

```clojure
(defn extrel-trace [base-ds]
  (let [trace (atom [])
        ds (reify
             ExtRel
             (extrel [_ consts starts whiles]
               (let [args [consts starts whiles]
                     ret (datomic.datalog/extrel base-ds consts starts whiles)]
                 (swap! trace conj {:args args :ret ret})
                 ret)))]
    [ds trace]))
```

And let's try it on a simple query:

```clojure
(let [[ds t] (extrel-trace [["e1" :int 1 "extra"]
                            ["e1" :int 2 "extra"]
                            ["e1" :int 3 "extra"]
                            ["e1" :int 4 "extra"]
                            ["e1" :int 5 "extra"]
                            ["e2" :int 2 "extra"]])]
  [(d/q '[:find ?v ?extra
          :in $
          :where
          [(ground ["e1" "e2"]) [?e ...]]
          [$ ?e :int ?v ?extra]
          [(= "extra" ?extra)]
          [(< ?v 4)]
          [(> ?v 1)]]
        ds)
   @t])
=>
[#{[2 "extra"] [3 "extra"]}
 [{:args [[nil :int nil nil]
          [nil nil 1 "extra"]
          [nil
           nil
           #object[datomic.datalog$ranges$fn__18296$fn__18300 0x35ac0c98 "datomic.datalog$ranges$fn__18296$fn__18300@35ac0c98"]
           #object[datomic.datalog$ranges$fn__18296$fn__18300 0x20fe78e3 "datomic.datalog$ranges$fn__18296$fn__18300@20fe78e3"]]],
   :ret (["e1" :int 1 "extra"]
         ["e1" :int 2 "extra"]
         ["e1" :int 3 "extra"]
         ["e1" :int 4 "extra"]
         ["e1" :int 5 "extra"]
         ["e2" :int 2 "extra"])}]]
```

This query had exactly one data-pattern clause in it: `[?e :int ?v ?extra]`.
The `extrel` method invocation corresponds to this clause.
Even though there are two possible values of `?e`,
`extrel` was only called once.
This is because `extrel`'s responsibility isn't to join against the 
results of previous binding clauses,
but only provide relations which can be determined from a static examination
of the query and its `:in` arguments.
(We'll illustrate this point better later.)

This call illustrates the structure of the `consts` `starts` and `whiles` 
parameters.
All three parameters will have the same length as the data-pattern clause,
less the optional `src-var` (in this case `$`).
The call may include information from other surrounding clauses.

`consts` contains all constant values, or `nil` if the value in that slot 
is not constant.
Note that only `:int` is constant.
`?e` is not considered constant even though it has a `ground` value and 
could be known statically.
Instead, the result of the `ground` will be joined against the result of this
clause later--remember, `extrel` is not about joining.

#### Subrange optimizations

`starts` and `while` is an optimization available for datasources
which are able to return a subset of values.
Through knowledge of the primitive predicates `<` and `=` used 
with static arguments datalog was able to determine that `?v` must be >= 1 
and `?extra` must start with the string `"extra"`.
Therefore the corresponding slots of `starts` have non-nil values
where a containing start value is known: `[nil nil 1 "extra"]`.

`while` is the same information, but for the end of the range.
Each item in the corresponding slot is a predicate which returns false
if the value in that slot of a candidate tuple is outside the end range.

```clojure
;; *1 is the previous result
(let [[_ _ while-v while-extra] (-> *1 peek first :args peek)]
  (mapv (juxt identity while-v) (range 6)))
=> [[0 true] [1 true] [2 true] [3 true] [4 false] [5 false]]
```

A datasource can use `starts` and `whiles` information--especially if it's 
available in a sorted order--to return a subset of its relations which could
never possibly join with anything else in the query.
All a sorted datasource has to do is start seeking at the `starts` slot of its 
choice and `take-while` the corresponding `while` slot predicate.

However, applying `starts` and `whiles` is (as far as I can tell) 
_completely optional_ for the correctness of the query.
If a datasource understands them it can leverage them to reduce the size
of relations it returns and thus the number of items involved in subsequent 
joins, but it is only _required_ to return items which satisfy `consts`.

You'll notice in the trace above that the `extrel` method of
`j.u.Collection` included `["e1" :int 5 "extra"]`
even though this doesn't satisfy `whiles`.
From what I can tell, the `j.u.Collections` implementation
only filters all items by `consts` and doesn't use `starts` or `whiles`.

### Datomic Database Datasources

However, a Datomic database *does* provide sorted items,
and *can* leverage `starts` and `whiles` to reduce its result-set.
Based on the non-nil `consts`, `starts`, and `whiles` slots
it can choose an appropriate index to seek.
For example, if the attribute is known and its values are indexed
and the value start or "while" is known it can do a sub-seek of `:avet`.

Let's trace the `extrel` call of an actual Datomic datasource.
We'll use a freshly-created dev connection instead of an in-memory connection
so that io-stats will tell us what indexes we are using.

```clojure
(let [[ds t] (extrel-trace db)]
  (-> (d/query {:query       '[:find ?v
                               :where
                               [?e :db/ident ?v]
                               [(<= :db/a ?v)]
                               [(< ?v :db/b)]]
                :args        [ds]
                :query-stats true
                :io-context  :user/query})
      (assoc :extrel-trace @t)))
=>
{:ret #{[:db/add]},
 :io-stats {:io-context :user/query,
            :api :query,
            :api-ms 5.18,
            :reads {:avet 1, :dev 1, :ocache 1, :dev-ms 1.57, :avet-load 1}},
 :query-stats {:query [:find ?v :where [?e :db/ident ?v] [(<= :db/a ?v)] [(< ?v :db/b)]],
               :phases [{:sched (([?e :db/ident ?v] [(<= :db/a ?v)] [(< ?v :db/b)])),
                         :clauses [{:clause [?e :db/ident ?v],
                                    :rows-in 0,
                                    :rows-out 1,
                                    :binds-in (),
                                    :binds-out [?v],
                                    :preds ([(<= :db/a ?v)] [(< ?v :db/b)]),
                                    :expansion 1,
                                    :warnings {:unbound-vars #{?v ?e}}}]}]},
 :extrel-trace [{:args [[nil :db/ident nil]
                        [nil nil :db/a]
                        [nil
                         nil
                         #object[datomic.datalog$ranges$fn__18296$fn__18300 0x3461f77c "datomic.datalog$ranges$fn__18296$fn__18300@3461f77c"]]],
                 :ret #object[datomic.datalog.DbRel 0x2e373360 "datomic.datalog.DbRel@2e373360"]}]}
```
There are three things to note here:

1. Alias resolution is the responsibility of the datasource.
2. Index choice is partially the responsibility of `extrel`.
3. The return value of `extrel` is not necessarily a concrete collection but
   anything that implements `datomic.datalog/IJoin`.

First, the `:db/ident` attribute keyword constant was supplied to the query.
Datoms don't have attribute idents (keywords) in them;
rather they have the [attribute's entity id][datomic-entity-id-datom].
The Datomic database datasource must translate this to an entity id number.
This means if the datasource has any aliasing mechanism
that allows queries to refer to values in relations
by anything other than their raw value,
it's the responsibility of the datasource to normalize those aliases
into their canonical form.

Second, notice from the `:io-stats` information that the query used the `:avet`
index for its reads.
This index choice is also the responsibility of the datasource.
In this case, it used the pattern of `consts`, `start`, and `while` to choose
the `:avet` index.

If we don't supply something that the datalog engine can recognise as a 
`start` or `while` parameter, the datasource may choose a different index:

```clojure
;; Using a custom predicate to hide the subrange selection from datalog
(defn db-starts-with-a [x]
  (and (= "db" (namespace x))
       (.startsWith (name x) "a")))

(let [[ds t] (extrel-trace db)]
  (-> (d/query {:query       '[:find ?v
                               :where
                               [?e :db/ident ?v]
                               [(user/db-starts-with-a ?v)]]
                :args        [ds]
                :query-stats true
                :io-context  ::query})
      (assoc :extrel-trace @t)))

=>
{:ret #{[:db/add]},
 :io-stats {:io-context :user/query,
            :api :query,
            :api-ms 5.56,
            :reads {:aevt 2, :dev 2, :aevt-load 2, :ocache 2, :dev-ms 2.28}},
 :query-stats {:query [:find ?v :where [?e :db/ident ?v] [(user/db-starts-with-a ?v)]],
               :phases [{:sched (([?e :db/ident ?v] [(user/db-starts-with-a ?v)])),
                         :clauses [{:clause [?e :db/ident ?v],
                                    :rows-in 0,
                                    :rows-out 1,
                                    :binds-in (),
                                    :binds-out [?v],
                                    :preds ([(user/db-starts-with-a ?v)]),
                                    :expansion 1,
                                    :warnings {:unbound-vars #{?v ?e}}}]}]},
 :extrel-trace [{:args [[nil :db/ident nil] [nil nil nil] [nil nil nil]],
                 :ret #object[datomic.datalog.DbRel 0x99687c4 "datomic.datalog.DbRel@99687c4"]}]}
```

Notice in this case the io-stats reports reading two `:aevt` index segments
instead of one `:avet` segment;
but the query stats look mostly the same except for the `:preds` clause.
In this case the `extrel` returned something which would seek all idents
instead of a subset of them, so more (potential) IO was performed.

Why didn't `:query-stats` show this difference?
It still reports "rows-out" as 1.
This is because of the third thing to notice,
which is that the `extrel` call didn't return a collection
but something called a `DbRel`.
What is this?

#### The `IJoin` Protocol

Datasources actually have a pair of protocols which are needed to evaluate
a query.
The first one is `ExtRel`, which we have just covered in detail.
But the second one is _what extrel returns_.
Although the simple builtin `extrel` implementations simply return a collection,
what extrel is _actually_ expected to return is something which implements
`datomic.datalog/IJoin`.

```clojure
datomic.datalog/IJoin
=>
{:on datomic.datalog.IJoin,
 :on-interface datomic.datalog.IJoin,
 :sigs {:join-project {:name join-project, :arglists ([xs ys join-map project-map-x project-map-y predctor]), :doc nil},
        :join-project-with {:name join-project-with,
                            :arglists ([ys xs join-map project-map-x project-map-y predctor]),
                            :doc nil}},
 :var #'datomic.datalog/IJoin,
 :method-map {:join-project-with :join-project-with, :join-project :join-project},
 :method-builders {#'datomic.datalog/join-project #object[datomic.datalog$fn__17492 0x1a9d7f3c "datomic.datalog$fn__17492@1a9d7f3c"],
                   #'datomic.datalog/join-project-with #object[datomic.datalog$fn__17513 0x27dd69e9 "datomic.datalog$fn__17513@27dd69e9"]},
 :impls {java.util.Collection {:join-project #object[datomic.datalog$fn__17586 0x1d8e070c "datomic.datalog$fn__17586@1d8e070c"],
                               :join-project-with #object[datomic.datalog$fn__17588 0x32170047 "datomic.datalog$fn__17588@32170047"]},
         java.lang.Object {:join-project #object[datomic.datalog$fn__17590 0x4302eda6 "datomic.datalog$fn__17590@4302eda6"],
                           :join-project-with #object[datomic.datalog$fn__17592 0xfdc460e "datomic.datalog$fn__17592@fdc460e"]},
         datomic.datalog.DbRel {:join-project #object[datomic.datalog$fn__17661 0x6287869e "datomic.datalog$fn__17661@6287869e"],
                                :join-project-with #object[datomic.datalog$fn__17663 0x6898a7b1 "datomic.datalog$fn__17663@6898a7b1"]}}}
```

Note that `j.u.Collection` implements `IJoin`, which is why you can return
a normal collection from `extrel`.

From this protocol map, we know the protocol definition looked something
like this:

```clojure
(defprotocol IJoin
  (join-project [xs ys join-map project-map-x project-map-y predctor])
  (join-project-with [xs ys join-map project-map-x project-map-y predctor]))
```

I must confess I have no idea what `join-project` is for.
I've never observed it invoked.

However, `join-project-with` is the method that performs a join, projection, 
and filtering from two `IJoin`-ables `xs` and `ys`.
(Read "project" as a verb, not a noun.)

Here's an instrumented example of the `join-project-with` call.
The code below reifies an `ExtRel` datasource which returns a reified `IJoin`.

```clojure
(def trace (atom []))
(d/query {:query '[:find ?e ?a ?v
                   :in $
                   :where
                   [?e :int ?i]
                   [(< 1 ?i)]
                   [(<= ?i 2)]
                   [?e :str ?str]
                   [(clojure.string/starts-with? ?str "foo")]
                   [?e ?a ?v]
                   ]
          :args
          (let [ds [["e1" :int 1]
                    ["e1" :int 2]
                    ["e1" :str "foo"]
                    ["e1" :str "bar"]
                    ["e2" :int 1]
                    ["e2" :str "baz"]]]
            [(reify ExtRel
               (extrel [_ consts starts whiles]
                 (let [xs (datomic.datalog/extrel ds consts starts whiles)]
                   (swap! trace conj {:fn 'extrel :args [consts starts whiles] :ret xs})
                   (reify
                     IJoin
                     (join-project-with [_ ys join-map project-map-x project-map-y predctor]
                       (let [r (datomic.datalog/join-project-with
                                xs
                                ys
                                join-map
                                project-map-x
                                project-map-y
                                predctor)]
                         (swap! trace conj
                                {:fn   'join-project-with
                                 :args [xs ys join-map project-map-x project-map-y predctor]
                                 :ret  r})
                         r))))))])})
```

Now lets look at the trace which I have annotated inline:

```clojure
@trace
[
 ;; This is for the clauses [?e :int ?i] [(< 1 ?i)] [(<= ?i 2)]
 {:fn extrel,
  :args [[nil :int nil]
         [nil nil 1]
         [nil
          nil
          #object[datomic.datalog$ranges$fn__18296$fn__18300 0x5474264c "datomic.datalog$ranges$fn__18296$fn__18300@5474264c"]]],
  :ret (["e1" :int 1] ["e1" :int 2] ["e2" :int 1])}
 ;; Now we join the result against an empty initial result set
 {:fn join-project-with,
  :args [(["e1" :int 1] ["e1" :int 2] ["e2" :int 1]) ;; previous extrel
         #{[]}                                       ;; initial result set
         {}                                          ;; no joins
         ;; Projection of xs:
         ;; Put slot 2 in xs into slot 0 in the result
         ;; Put slot 0 in xs into slot 1 in the result
         {2 0, 0 1}
         ;; Projection of ys: keep nothing
         {}
         ;; This is a predicate constructor.
         ;; When called, it will return predicates which should be called
         ;; to filter results.
         ;; This is why `extrel` doesn't need to honor `starts` and `whiles`--
         ;; this is what *really* does the filtering.
         #object[datomic.datalog$push_preds$fn__18015$fn__18027 0x33a1ac5e "datomic.datalog$push_preds$fn__18015$fn__18027@33a1ac5e"]],
  :ret #{[2 "e1"]}}
 ;; Now we get the extrel for [?e :str ?str]
 ;; Note the `starts-with?` predicate is not included.
 {:fn extrel,
  :args [[nil :str nil] [nil nil nil] [nil nil nil]],
  :ret (["e1" :str "foo"] ["e1" :str "bar"] ["e2" :str "baz"])}
 ;; Now join this extrel with the result of the previous IJoin
 {:fn join-project-with,
  :args [(["e1" :str "foo"] ["e1" :str "bar"] ["e2" :str "baz"])
         ;; This is the result of the previous IJoin
         ;; It is *always* a set.
         ;; Note the tuple slots correspond to the projection maps.
         #{[2 "e1"]}
         ;; Join slot 0 in xs to slot 1 in ys
         ;; Here, it means only include tuples with "e1"
         {0 1}
         ;; Project xs 2 to 0, 0 to 1
         {2 0, 0 1}
         ;; Project ys 1 to 1
         ;; Since 1 in the result is the join target of xs and ys,
         ;; this is ok--they will never conflict.
         {1 1}
         ;; This has the `starts-with?` predicate in it.
         #object[datomic.datalog$push_preds$fn__18015$fn__18027 0x2590becd "datomic.datalog$push_preds$fn__18015$fn__18027@2590becd"]],
  :ret #{["foo" "e1"]}}
 ;; This final extrel is for the clause [?e ?a ?v]
 ;; On datomic databases, this would eventually throw because it is a full scan.
 ;; That behavior is from the datasource implementation, not the datalog!
 {:fn extrel,
  :args [[nil nil nil] [nil nil nil] [nil nil nil]],
  :ret [["e1" :int 1] ["e1" :int 2] ["e1" :str "foo"] ["e1" :str "bar"] ["e2" :int 1] ["e2" :str "baz"]]}
;; The final projection is to extract what the `:find` clause wants.
 {:fn join-project-with,
  :args [[["e1" :int 1] ["e1" :int 2] ["e1" :str "foo"] ["e1" :str "bar"] ["e2" :int 1] ["e2" :str "baz"]]
         #{["foo" "e1"]}
         {0 1}
         {0 0, 1 1, 2 2}
         {1 0}
         #object[datomic.datalog$truep 0x4922463b "datomic.datalog$truep@4922463b"]],
  :ret #{["e1" :str "bar"] ["e1" :int 1] ["e1" :int 2] ["e1" :str "foo"]}}]
```

If you compare this trace with the `:query-stats` output of the query,
you'll notice that its data roughly corresponds to `join-project-with` 
invocations (including row counts) more than the `extrel` invocations.
In general, `:io-stats` tells you more about the relations from `extrel`
and `:query-stats` about `join-project-with` calls.

#### Realizing Relations in IJoin

The existing of `IJoin` as a protocol allows `ExtRel` to defer realization
of the relation until it receives more information from join parameters.
In this case, `DbRel` isn't actually reading any datoms--this happens
during its `IJoin`, where it can make better index choices.

This `ExtRel` vs `IJoin` split also explains a lot of seemingly inconsistent 
behavior in datalog queries around lookup-ref resolution.
The inconsistency often comes down to whether the lookup could be resolved 
at `extrel` time or at `join-project-with` time.

Take the following query as an example.

```clojure
(let [[ds t] (extrel-trace db)]
  (-> (d/query {:query       '[:find ?v
                               :in $ [?a ?v]
                               :where
                               [:db.part/db ?a ?v]]
                :args        [ds [:db.install/attribute :db/doc]]
                :io-context :user/query
                :query-stats true})
      (assoc :extrel-trace @t)))

=>
{:ret #{[:db/doc]},
 :io-stats {:io-context :user/query,
            :api :query,
            :api-ms 4.26,
            :reads {:aevt 1, :dev 1, :aevt-load 1, :ocache 1, :dev-ms 1.11}},
 :query-stats {:query [:find ?v :in $ [?a ?v] :where [:db.part/db ?a ?v]],
               :phases [{:sched (([(ground $__in__2) [?a ?v]] [:db.part/db ?a ?v])),
                         :clauses [{:clause [(ground $__in__2) [?a ?v]],
                                    :rows-in 0,
                                    :rows-out 1,
                                    :binds-in (),
                                    :binds-out [?a ?v],
                                    :expansion 1}
                                   {:clause [:db.part/db ?a ?v],
                                    :rows-in 1,
                                    :rows-out 1,
                                    :binds-in [?a ?v],
                                    :binds-out [?v]}]}]},
 :extrel-trace [{:args [[:db.part/db :db.install/attribute :db/doc] [nil nil nil] [nil nil nil]],
                 :ret #object[datomic.datalog.DbRel 0x750e1765 "datomic.datalog.DbRel@750e1765"]}]}
```

In this query the `[?a ?v]` is a single tuple and not a relation,
so the value of `?a` and `?v` are effectively constant.
Thus datalog knows it can supply them as `consts` to `extrel`,
which can interpret them as lookups.
And you can see in the `extrel-trace` that `:db.install/attribute` and 
`:db/doc` were both provided, so `extrel` knew the attribute was a ref
and the value should be resolved to a ref.

But the following seemingly semantically identical query
gives a different result:

```clojure
(let [[ds t] (extrel-trace db)]
  (-> (d/query {:query       '[:find ?v
                               :in $ [[?a ?v]]
                               :where
                               [:db.part/db ?a ?v]]
                :args        [ds [[:db.install/attribute :db/doc]]]
                :io-context  :user/query
                :query-stats true})
      (assoc :extrel-trace @t)))

=>
{:ret #{},
 :io-stats {:io-context :user/query,
            :api :query,
            :api-ms 4.55,
            :reads {:aevt 6, :dev 4, :aevt-load 6, :ocache 6, :dev-ms 3.81}},
 :query-stats {:query [:find ?v :in $ [[?a ?v]] :where [:db.part/db ?a ?v]],
               :phases [{:sched (([(ground $__in__2) [[?a ?v]]] [:db.part/db ?a ?v])),
                         :clauses [{:clause [(ground $__in__2) [[?a ?v]]],
                                    :rows-in 0,
                                    :rows-out 1,
                                    :binds-in (),
                                    :binds-out [?a ?v],
                                    :expansion 1}
                                   {:clause [:db.part/db ?a ?v],
                                    :rows-in 1,
                                    :rows-out 0,
                                    :binds-in [?a ?v],
                                    :binds-out [?v]}]}]},
 :extrel-trace [{:args [[:db.part/db nil nil] [nil nil nil] [nil nil nil]],
                 :ret #object[datomic.datalog.DbRel 0x329effe3 "datomic.datalog.DbRel@329effe3"]}]}
```

In this case, the `?a` and `?v` were part of a relation
and so were not provided to the `extrel` of the data-pattern clause for the
Datomic datasource.
For this to work correctly,
the alias resolution would have to happen in the `join-project-with`,
where it is more difficult to determine
if a value should be resolved as a lookup ref.

Note that the `:query-stats` for both queries have nearly identical row-counts
because they would be the same from the perspective of the `join-project-with`
clauses.
Only the difference in `:io-context` reveals that the `extrel` call for the 
second query was clearly seeking more datoms.

Implementing your own `IJoin`-able is more difficult than your own `ExtRel`
because you need to rely on even more interfaces to actually perform the
projection, joining, and filtering required.
Probably anything that is reduce-able and whose elements are indexed will work,
but I don't know for sure and I won't explore it here.

However, `ExtRel` is pretty easy to fulfil!

## Custom Datasources

So far we have just looked at "built-in" datasources:
collections and Datomic databases.
But because its behavior is governed by the `ExtRel` protocol
we can create our own datasources by implementing this protocol.

We just need to follow these rules:

* `ExtRel` takes consts, starts, and take-while predicates and returns 
  a relation implementing `IJoin` which only supplies tuples matching `consts`.
  Implementations _may_ use `starts` and `whiles` to return a subset of 
  things matching `consts`.
* `IJoin` performs projection, unification, and filtering
  against another `IJoin`
  and returns the result as another `IJoin`-able, typically a set of tuples.
  The `IJoin` object may close over information from the `ExtRel` that supplied
  it to defer decisions to join-time if it wants.

Let's look at some simple examples of useful custom datasources.

### Transaction Data with Ident Syntax for Attributes

Tx-data from a transaction is a set of datoms.

```clojure
(:tx-data (d/with db [{:db/id "new" :db/doc "My new entity"}]))
=>
[#datom[13194139534312 50 #inst"2024-06-18T21:07:05.141-00:00" 13194139534312 true]
 #datom[17592186045417 62 "My new entity" 13194139534312 true]]
```

Conceptually, this is the same as a Datomic database.
However, as we have seen, the `extrel` of a Datomic database does ident
resolution of attributes that normal collections don't,
so this query doesn't work:

```clojure
(let [{:keys [tx-data db-after]} (d/with db [{:db/id "new" :db/doc "My new entity"}])
      query '[:find ?e :where [?e :db/doc "My new entity"]]]
  [
   (d/q query db-after)
   (d/q query tx-data)
   ])
=> [#{[17592186045417]} ;; Works as expected with a normal db
    #{}]                ;; Fails with tx-data
```

But, what if it _could_ work?
All we need is an `extrel` that resolves attributes in its `consts` to their
entity id:

```clojure
(defn tx-data-extrel [db tx-data]
  (reify ExtRel
    (extrel [_ consts _starts _whiles]
      (let [resolve-ref #(d/entid db %)
            [c-e c-araw c-vraw c-tx c-op] consts
            c-e (resolve-ref c-e)
            attr (when (some? c-araw)
                   (or (d/attribute db c-araw)
                       (throw (ex-info "Unknown attribute reference" {:attr c-araw}))))
            c-a (:id attr)
            ref-v? (= :db.type/ref (:value-type attr))
            c-v (if ref-v?
                  (when (some? c-vraw)
                    (or (d/entid db c-vraw)
                        (throw (ex-info "Could not resolve entity reference" {:ref c-vraw}))))
                  c-vraw)
            c-tx (resolve-ref c-tx)
            xfs (cond-> []
                        (some? c-e) (conj (filter #(== ^long c-e ^long (:e %))))
                        (some? c-a) (conj (filter #(== ^long c-a ^long (:a %))))
                        (some? c-v) (conj (filter #(= c-v (:v %))))
                        (some? c-tx) (conj (filter #(== ^long c-tx ^long (:tx %))))
                        (some? c-op) (conj (filter #(= c-op (:op %)))))]
        (into [] (apply comp xfs) tx-data)))))
```

Now if we use this to wrap the tx-data, we can query using attribute idents:

```clojure
(let [{:keys [tx-data db-after]} (d/with db [{:db/id "new" :db/doc "My new entity"}])
      query '[:find ?e :where [?e :db/doc "My new entity"]]]
  (d/q query (tx-data-extrel db-after tx-data)))
=> #{[17592186045417]}
```

Voilà!

Notice that we return a normal collection as the `IJoin`-able,
which means that attributes that are supplied as relations still won't resolve.

For example:

```clojure
(let [{:keys [tx-data db-after]} (d/with db [{:db/id "new" :db/doc "My new entity"}])
      query '[:find ?e
              :where
              [(ground [:db/doc]) [?a ...]]
              ;; ?a is not recognized as a scalar constant
              [?e ?a "My new entity"]]]
  (d/q query (tx-data-extrel db-after tx-data)))
=> #{} ;; Does not match!
```

Compare with a normal Datomic database, where the `DbRel`
or something in it *is* doing some resolution of attribute references:

```clojure
(let [{:keys [tx-data db-after]} (d/with db [{:db/id "new" :db/doc "My new entity"}])
      query '[:find ?e
              :where
              [(ground [:db/doc]) [?a ...]]
              [?e ?a "My new entity"]]]
  (d/q query db-after))
=> #{[17592186045417]} ;; Works!
```

I'll leave that enhancement as an exercise for the reader!

### Subset Relations from Sorted Sets

Perhaps you have a datasource which is large and sorted.
You could just use it as a normal `j.u.Collection`,
but as we saw, the built-in implementation can't take advantage of sorted-ness.

But what if you could use `starts` and `whiles` information
to return a smaller relation and join across fewer rows?

Perhaps like this:

```clojure
(defn sorted-set-extrel [s width]
  ;; width is how many slots per element tuple, which is needed because the
  ;; default comparator compares length before element content.
  ;; Assumes set `s` is sorted by its elements and does not contain nil anywhere.
  ;; Does not assume set has a nil-safe custom comparator, but it's a good enhancement!
  (reify ExtRel
    (extrel [_ consts starts whiles]
      ;; We always have to filter by constants
      (let [consts-pred (if-some [preds (not-empty
                                         (into []
                                               (comp
                                                (map-indexed (fn [i v] (when v #(= v (nth % i)))))
                                                (filter some?))
                                               consts))]
                          (apply every-pred preds)
                          (constantly true))
            ;; Lets see if "starts" has non-nil prefixes; if so we can use them!
            usable-starts (when-some [prefix (not-empty
                                              (take-while some? starts))]
                            ;; Padding the suffix for the builtin comparator
                            (vec (concat prefix
                                         (repeat (- width (count prefix)) nil))))
            ;; Use non-nil prefix predicates from whiles too
            usable-whiles (not-empty
                           (into []
                                 (comp
                                  (take-while some?)
                                  (map-indexed (fn [i f] #(f (nth % i)))))
                                 whiles))]
        (filterv consts-pred
                 (if usable-starts
                   (cond->> (subseq s >= usable-starts)
                            usable-whiles (take-while (apply every-pred usable-whiles)))
                   s))))))
```

Let's use a 16000-row set as an example.

```clojure
(def myset (apply sorted-set
                  (for [i (range 1000)
                        j ["a" "b" "c" "d"]
                        k ["a" "b" "c" "d"]]
                    [i j k])))

(count myset)
=> 16000
```

If we query a range of this set as a normal collection,
many more items will be returned.
We won't see any difference in row-counts the `:query-stats`,
but we should see higher `:api-ms` in io-stats.

```clojure
(def query
  '[:find ?i ?j ?k
    :where
    [(ground "b") ?k]
    [?i ?j ?k]
    [(< 10 ?i)]
    [(< ?i 13)]])
```

Running this query a few times on a normal set,
`:api-ms` stablizes at about 8 ms on my machine.

```clojure
(d/query {:query query :args [myset] :query-stats true :io-context ::query})
=>
{:ret #{[11 "d" "b"] [11 "c" "b"] [12 "d" "b"] [11 "b" "b"] [12 "c" "b"] [11 "a" "b"] [12 "b" "b"] [12 "a" "b"]},
 :io-stats {:io-context :user/query, :api :query, :api-ms 8.1, :reads {}},
 :query-stats {:query [:find ?i ?j ?k :where [(ground "b") ?k] [?i ?j ?k] [(< 10 ?i)] [(< ?i 13)]],
               :phases [{:sched (([(ground "b") ?k] [?i ?j ?k] [(< 10 ?i)] [(< ?i 13)])),
                         :clauses [{:clause [(ground "b") ?k],
                                    :rows-in 0,
                                    :rows-out 1,
                                    :binds-in (),
                                    :binds-out [?k],
                                    :expansion 1}
                                   {:clause [?i ?j ?k],
                                    :rows-in 1,
                                    :rows-out 8,
                                    :binds-in [?k],
                                    :binds-out [?k ?j ?i],
                                    :preds ([(< 10 ?i)] [(< ?i 13)]),
                                    :expansion 7}]}]}}
```

But if we use the custom `ExtRel`, it's a bit under 1 ms!

```clojure
(d/query {:query query :args [(sorted-set-extrel myset 3)] :query-stats true :io-context ::query})
=>
{:ret #{[11 "d" "b"] [11 "c" "b"] [12 "d" "b"] [11 "b" "b"] [12 "c" "b"] [12 "b" "b"] [11 "a" "b"] [12 "a" "b"]},
 :io-stats {:io-context :user/query, :api :query, :api-ms 0.82, :reads {}},
 :query-stats {:query [:find ?i ?j ?k :where [(ground "b") ?k] [?i ?j ?k] [(< 10 ?i)] [(< ?i 13)]],
               :phases [{:sched (([(ground "b") ?k] [?i ?j ?k] [(< 10 ?i)] [(< ?i 13)])),
                         :clauses [{:clause [(ground "b") ?k],
                                    :rows-in 0,
                                    :rows-out 1,
                                    :binds-in (),
                                    :binds-out [?k],
                                    :expansion 1}
                                   {:clause [?i ?j ?k],
                                    :rows-in 1,
                                    :rows-out 8,
                                    :binds-in [?k],
                                    :binds-out [?k ?j ?i],
                                    :preds ([(< 10 ?i)] [(< ?i 13)]),
                                    :expansion 7}]}]}}
```

Note that the query-stats isn't any different, only the io-stats!

### Time-traveling Datasources

One limitation of Datomic queries is that you cannot re-parameterize a database
within a query.
So for example, you can't do something like this:

```clojure
[:find ?e ?as-of-tx ?v
 :in $normal $history
 :where
 ;; At moments when ?e :my/attr changed ...
 [$history ?e :my/attr _ ?as-of-tx]
 ;; ... what was the corresponding value of :my/other-attr ?
 [$normal-but-as-of-tx ?e :my/other-attr ?v]]
```

But what would it take to make this possible?
An approach could be to extend the tuple syntax
to pretend that the first slot is an as-of parameter, like so:

```clojure
[$ ?as-of-tx ?e :my/other-attr ?v]
```

The `extrel` implementation could do something like this:

```clojure
(reify ExtRel
       (extrel [_ consts starts whiles]
               (datomic.datalog/extrel
                (db/as-of normal-db (first consts))
                (rest consts)
                (rest starts)
                (rest whiles))))
```

But this only works in the simplest possible case where the as-of value
`(first consts)` is non-nil (i.e. a query-constant).
Even in our example query this is not the case.
To get the sample query working as expected,
we need to return something `IJoin`-compatible which interprets the first 
tuple slot as an as-of parameter during the `join-project-with`,
uses that to set the as-of of the database,
then delegates the join to the `DbRel` of that database.

In other words, something like this:

```clojure
(defn as-of-db [db]
  (reify ExtRel
    (extrel [_ consts starts whiles]
      (let [as-of (first consts)
            consts (vec (rest consts))
            starts (vec (rest starts))
            whiles (vec (rest whiles))]
        (if (some? as-of)
          ;; as-of is query scalar constant
          (datomic.datalog/extrel (d/as-of db as-of) consts starts whiles)
          ;; as-of will come from a later join
          (reify IJoin
            (join-project-with [_ ys join-map pmx pmy predctor]
             ;; Our column 0 is the as-of value.
             ;; What column in ys should join to it?
              (let [as-of-column-idx (get join-map 0)
                    _ (when (nil? as-of-column-idx) (throw (ex-info "as-of must be bound!" {})))
                    ;; Turn the single ys into a bunch of ys grouped by db-as-of
                    ys-by-as-of (group-by #(nth % as-of-column-idx) ys)
                    ;; We need to rewrite the join and project-x maps to reflect that the as-of column doesn't exist in datoms
                    join-map' (into {}
                                    (keep (fn [[^long x ^long y]]
                                            [(dec x) y]))
                                    (dissoc join-map 0))
                    pmx' (into {}
                               (keep (fn [[^long x ^long y]]
                                       [(dec x) y]))
                               (dissoc pmx 0))]
                (into #{}
                      (mapcat (fn [[as-of ys']]
                                ;; Use the as-of value to set the database ...
                                (let [dbrel (datomic.datalog/extrel (d/as-of db as-of) consts starts whiles)]
                                  ;; and perform a join as usual!
                                  ;; Because the as-of value *must* be supplied by the ys *and* joined,
                                  ;; we know that if it is wanted in the output it will be projected via pmy,
                                  ;; so we can rely on the normal dbrel to assemble the output correctly for us.
                                  (datomic.datalog/join-project-with dbrel ys' join-map' pmx' pmy predctor))))
                      ys-by-as-of)))))))))
```

And a demonstration of use:

```clojure
(let [{db :db-after} (d/with db [{:db/ident       :my/attr
                               :db/valueType   :db.type/string
                               :db/cardinality :db.cardinality/one}
                              {:db/ident       :my/other-attr
                               :db/valueType   :db.type/string
                               :db/cardinality :db.cardinality/one}])
      {db :db-after} (d/with db [{:db/ident :my/entity
                                  :my/other-attr "oldvalue"}])
      {db :db-after} (d/with db [{:db/ident :my/entity
                                  :my/attr "ignored"}])
      {db :db-after} (d/with db [{:db/ident :my/entity
                                  :my/other-attr "newvalue"}])]
  (d/q
   '[:find ?e ?as-of-tx ?v
     :in $normal $history
     :where
     [$history ?e :my/attr _ ?as-of-tx]
     [$normal ?as-of-tx ?e :my/other-attr ?v]]
   (as-of-db db) (d/history db)))
=> #{[17592186045418 13194139534315 "oldvalue"]}
```

Pretty cool!

## Summary

Datomic's Datalog engine uses the `ExtRel` protocol on datasources to get 
relations--sets of tuples--which correspond to the data-pattern clauses in 
the query.
The `extrel` call includes query-wide constants
and sometimes start values and take-while predicates inferred from 
surrounding predicate-expression clauses.
The start and take-while predicates are advisory and
the datasource may use them to return a smaller relation.

The returned value must be an `IJoin`-able
which takes a pair of `IJoin`-ables, applies joins, projection, and filtering,
and returns the next result-set via the `join-project-with` method.
An `extrel` can defer realization of its relations to `join-project-with`,
and in fact this is what Datomic databases do via the `DbRel` "relation".
The advantage of this is you can make better index choices with more information
about the join;
the disadvantage is that it's a lot more complicated!

A datasource is responsible for any aliasing behavior
(such as keywords for attribute ids)
in its implementations of `extrel` and `join-project-with`.

`:query-stats` gives information mostly about `join-project-with` calls;
deferred realization of relation members can often hide the true number of
rows examined by a datasource.
Clues to realized-relation sizes come from `:io-stats`.  

Finally, we looked at three toy examples of custom datasources:

* The tx-data example interprets aliases for more egonomic query syntax
  (attribute idents instead of numbers) over normal collections.
* The sorted-set example takes advantage of subrange information from `extrel`
  to produce smaller relations and faster query runtimes.
* Finally, we added extra within-query as-of parameterization of Datomic
  databases via an additional "virtual" column of the relation.
  This dipped a bit into `IJoin` and messing with joins and projections,
  but left the heavy-lifting to the default Datomic database implementation.

I hope you found this intriguing and enlightening!

[datomic-entity-id-datom]: {%link _posts/2024-05-16-datomic-entity-id-structure.markdown %}#datoms

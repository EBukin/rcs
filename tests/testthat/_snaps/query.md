# store_open() returns a lazy query that prints its dataset, files and columns

    Code
      q
    Output
      <rcs_query> sales/daily (table, current)
      Location: primary
      Files:    2 of 2
      Columns:  shop_id, date, year, product, qty, price, promo, grade, delivered, big, wait, note, tags, ts, ts_local

---

    Code
      dplyr::filter(q, year == 2024)
    Output
      <rcs_query> sales/daily (table, current)
      Location: primary
      Files:    1 of 2
      Columns:  shop_id, date, year, product, qty, price, promo, grade, delivered, big, wait, note, tags, ts, ts_local

---

    Code
      store_open(fx$st, "nothing")
    Condition
      Error in `store_open()`:
      ! No dataset "nothing" in the store.

# a lazy query reads from the location store_read() would read from

    Code
      q <- store_open(st, "sales/summary")
    Message
      i Reading "sales/summary" from secondary <secondary1>.

---

    Code
      q
    Output
      <rcs_query> sales/summary (table, current)
      Location: secondary 1
      Files:    1 of 1
      Columns:  shop_id, date, year, product, qty, price, promo, grade, delivered, big, wait, note, tags, ts, ts_local

# verbs abort as dplyr does, with the query's message

    Code
      dplyr::filter(q, qty > 1, .by = shop_id)
    Condition
      Error in `dplyr::filter()`:
      ! `.by` is not supported for <rcs_query>.

---

    Code
      store_intersects("not a query", 1)
    Condition
      Error in `store_intersects()`:
      ! `q` must be a query made by `store_open()`.


%% Source and dest addrs.
-type addr() :: string().
-type ton()  :: 0 | 1 | 2 | 3 | 4 | 5 | 6.
-type npi()  :: 0 | 1 | 3 | 4 | 6 | 8 | 9 | 10 | 14 | 18.
-type full_addr() :: {addr(), ton(), npi()}.

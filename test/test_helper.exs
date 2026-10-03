# Keep tests out of the real host data dir (_build/host_data): anything that
# resolves Operator.Paths.data_dir/0 (key store, sessions, notes) writes here.
data_dir = Path.join(System.tmp_dir!(), "operator-test-#{System.unique_integer([:positive])}")
File.mkdir_p!(data_dir)
System.put_env("MOB_DATA_DIR", data_dir)

ExUnit.start()

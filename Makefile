GHC = ghc
OUT = results/
DB_SUITE = $(wildcard lib/DeBruijn/*.lhs lib/DeBruijn/*.hs lib/DeBruijn/*/*.lhs)
LN_SUITE = $(wildcard lib/LocallyNameless/*.hs lib/DeBruijn/*/*.hs)
NM_SUITE = $(wildcard lib/Named/*.hs lib/Named/*.lhs)
SUITE = $(DB_SUITE) $(LN_SUITE) $(NM_SUITE)
RESULTS = $(subst lib,results,$(subst .hs,.csv,$(subst .lhs,.csv,$(SUITE))))

LC:	lib/*.lhs lib/*/*.lhs bench/*.lhs 
#	$(GHC) -package mtl -O2 -Wall --make Main.lhs -o LC
	stack build --copy-bins --local-bin-path .

.PHONY: timing
timing:	LC
	stack run -- --output $(OUT)rand_bench.html --match prefix "rand/"  > $(OUT)output.txt
	stack run -- --output $(OUT)conv_bench.html --match prefix "conv/"  >> $(OUT)output.txt
	stack run -- --output $(OUT)nf_bench.html --match prefix "nf/"  >> $(OUT)output.txt
	stack run -- --output $(OUT)aeq_bench.html --match prefix "aeq/" >> $(OUT)output.txt
#	stack run -- --output $(OUT)con_bench.html --match prefix "con/" >> $(OUT)output.txt
#	stack run -- --output $(OUT)capt_bench.html --match prefix "capt/" >> $(OUT)output.txt

csv: $(RESULTS)

results/%.csv : Makefile lib/%.lhs
	mkdir -p $(@D)
	stack run -- --csv results/$*-rand.csv --match prefix "rand/$(subst /,.,$*)"
	stack run -- --csv results/$*-conv.csv --match prefix "conv/$(subst /,.,$*)"
	stack run -- --csv results/$*-nf.csv --match prefix "nf/$(subst /,.,$*)"
	stack run -- --csv results/$*-aeq.csv --match prefix "aeq/$(subst /,.,$*)"
	stack run -- --csv results/$*-con.csv --match prefix "con/$(subst /,.,$*)"
	stack run -- --csv results/$*-capt.csv --match prefix "capt/$(subst /,.,$*)"

timing_% : LC lib/$(@D)/$(@F).hs
	stack run -- --output $(OUT)con_bench.html --match prefix "con/$(@D).$(@F)" >> $(OUT)output.txt


.PHONY:	clean
clean:
	rm -f *.hi *.o LC 

married_jointly_table = [
    (0.0, 22000.0, 0.1),
    (22001.0, 89450.0, 0.12),
    (89451.0, 190750.0, 0.22),
    (190751.0, 364200.0, 0.24),
    (364201.0, 462500.0, 0.32),
    (462501.0, 693750.0, 0.35),
    (693751.0, float('inf'), 0.37)
]

married_separate_table = [
    (0.0, 11000.0, 0.1),
    (11001.0, 44725.0, 0.12),
    (44726.0, 95375.0, 0.22),
    (95376.0, 182100.0, 0.24),
    (182101.0, 231250.0, 0.32),
    (231251.0, 346875.0, 0.35),
    (346876.0, float('inf'), 0.37)
]

income_a = 65000.0
income_b = 230000.0
incomes = [income_a, income_b]

# jointly
income_joint = sum(incomes)
taxable_remaining = income_joint
bracket_idx = 0
tax_paid = 0.0

while taxable_remaining > 0.0:
    bracket_amt = married_jointly_table[bracket_idx][1] - married_jointly_table[bracket_idx][0]
    tax_bracket_rate = married_jointly_table[bracket_idx][2]
    taxable_amt = min(bracket_amt, taxable_remaining)

    bracket_tax = (taxable_amt * tax_bracket_rate)
    tax_paid += bracket_tax
    print(f"{bracket_tax:0.2f} for bracket: {married_jointly_table[bracket_idx]}")
    taxable_remaining -= taxable_amt
    bracket_idx += 1

print(f"Joint tax paid: {tax_paid:0.2f}")

# separate
combined_tax = 0.0
for income_individual in incomes:
    taxable_remaining = income_individual
    bracket_idx = 0
    inidividual_tax_paid = 0.0

    while taxable_remaining > 0.0:
        bracket_amt = married_separate_table[bracket_idx][1] - married_separate_table[bracket_idx][0]
        tax_bracket_rate = married_separate_table[bracket_idx][2]
        taxable_amt = min(bracket_amt, taxable_remaining)

        bracket_tax = (taxable_amt * tax_bracket_rate)
        inidividual_tax_paid += bracket_tax
        taxable_remaining -= taxable_amt
        bracket_idx += 1
    
    combined_tax += inidividual_tax_paid
    
print(f"Separate tax paid: {combined_tax:0.2f}")
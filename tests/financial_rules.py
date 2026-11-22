"""Lightweight checks for policy arithmetic. No database/network is used."""
from decimal import Decimal


def calculate(base, discount, teacher_discount=0):
    b, d, td = map(Decimal, map(str, (base, discount, teacher_discount)))
    assert 0 <= d <= b
    assert 0 <= td <= d and td <= b / 2
    return b-d, b / 2-td, b / 2-d+td


def test_regular_discount():
    assert calculate(2000, 500) == (1500, 1000, 500)


def test_teacher_approved_discount():
    assert calculate(2000, 500, 200) == (1500, 800, 700)


def test_partial_payment_not_teacher_cut():
    amount_due, teacher_share, center_share = calculate(2000, 500)
    payment = 600
    assert amount_due-payment == 900
    assert teacher_share == 1000
    assert center_share == 500


def test_equal_partners():
    units = [1, 1, 1]
    assert all(Decimal(u)/sum(units) == Decimal(1)/3 for u in units)

if __name__ == '__main__':
    test_regular_discount()
    test_teacher_approved_discount()
    test_partial_payment_not_teacher_cut()
    test_equal_partners()
    print('All arithmetic checks passed.')

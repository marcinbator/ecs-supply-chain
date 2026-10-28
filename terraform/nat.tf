resource "aws_eip" "nat" {
  domain = "vpc"
}

resource "aws_nat_gateway" "demo" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
}
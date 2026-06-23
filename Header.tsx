import React from 'react';

interface Props {
  title: string;
}

export const Header: React.FC<Props> = ({ title }) => {
  return (
    <div className="header">
      <h1>{title}</h1>
    </div
  );
};
